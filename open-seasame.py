import paramiko
import getpass
import json
import os
import time
import subprocess
import re
import signal
import sys
import socket

def check_port_availability(port):
    """Check if a port is available on localhost."""
    try:
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.settimeout(2)  # Add timeout
        result = sock.connect_ex(('127.0.0.1', port))
        sock.close()
        if result == 0:
            print(f"Port {port} is open and accepting connections")
        else:
            print(f"Port {port} is not accepting connections (error code: {result})")
        return result == 0
    except Exception as e:
        print(f"Error checking port {port}: {e}")
        return False

def create_submission_script(username):
    """Create the submission script with the correct username."""
    return f"""#!/bin/bash
#SBATCH --job-name={username}-jupyter
#SBATCH --output=combined.txt
#SBATCH --error=combined.txt
#SBATCH --time=03:00:00
#SBATCH --partition=mit_normal

# Print debug information
echo "Running job on $(hostname)"
echo "Current directory: $(pwd)"

# Load miniforge module
module load miniforge
echo "Loaded miniforge module"

# Initialize conda for bash
eval "$(conda shell.bash hook)"

# Check if jupyter_env exists
if conda env list | grep -q "jupyter_env"; then
    echo "Found existing jupyter_env, activating..."
    conda activate jupyter_env
else
    echo "Creating new jupyter_env..."
    # Create environment non-interactively
    conda create -y -n jupyter_env jupyterlab
    conda activate jupyter_env
fi

# Verify conda environment and Python version
echo "Active conda environment: $CONDA_DEFAULT_ENV"
echo "Python version: $(python --version)"
echo "JupyterLab version: $(jupyter-lab --version)"

# Start JupyterLab server in the background
jupyter-lab --no-browser --port=8874 --ip=0.0.0.0 &
JUPYTER_PID=$!

# Wait a moment for the server to start
sleep 5

# Check if the server is running
if ps -p $JUPYTER_PID > /dev/null; then
    echo "JupyterLab server started successfully with PID $JUPYTER_PID"
    netstat -tuln | grep 8874
else
    echo "Failed to start JupyterLab server"
    exit 1
fi

# Write the server info to a file for the Python script to read
echo "Waiting for JupyterLab server to write its info..."
while true; do
    if [ -d "$HOME/.local/share/jupyter/runtime" ]; then
        JSON_FILE=$(ls -t $HOME/.local/share/jupyter/runtime/jpserver-*.json 2>/dev/null | head -n1)
        if [ -n "$JSON_FILE" ]; then
            echo "Found JupyterLab server info at: $JSON_FILE"
            cat "$JSON_FILE" > $HOME/jupyter_server_info.json
            break
        fi
    fi
    sleep 2
done

# Keep the job running for 3 hours
sleep 10800  # 3 hours = 3 * 60 * 60 seconds

# Clean up the Jupyter process when the job ends
kill $JUPYTER_PID
"""

def get_compute_node(ssh, job_id):
    """Get the compute node where the job is running."""
    # Wait for the job to start and get its node
    max_attempts = 30
    delay = 10
    
    for attempt in range(max_attempts):
        print(f"Waiting for job to start on compute node (attempt {attempt + 1}/{max_attempts})...")
        stdin, stdout, stderr = ssh.exec_command(f'squeue -j {job_id} -o "%N" -h')
        node = stdout.read().decode().strip()
        
        if node and node != "(null)":
            print(f"Job is running on node: {node}")
            return node
            
        time.sleep(delay)
    
    raise Exception("Could not determine compute node for the job")

def wait_for_jupyter_server(ssh, home_dir, max_attempts=30, delay=10):
    """Wait for the Jupyter server to be ready."""
    for attempt in range(max_attempts):
        print(f"Waiting for Jupyter server to start (attempt {attempt + 1}/{max_attempts})...")
        
        # Check if the server info file exists
        stdin, stdout, stderr = ssh.exec_command(f'test -f {home_dir}/jupyter_server_info.json && echo exists')
        if not stdout.read().decode().strip():
            print("Server info file not found yet...")
            time.sleep(delay)
            continue
            
        # Try to read the JSON file
        try:
            sftp = ssh.open_sftp()
            with sftp.open(f'{home_dir}/jupyter_server_info.json', 'r') as remote_file:
                json_content = json.load(remote_file)
                if 'url' in json_content and 'token' in json_content:
                    print("\nJupyterLab server info found:")
                    print(f"URL: {json_content['url']}")
                    print(f"Token: {json_content['token']}")
                    return json_content
        except Exception as e:
            print(f"Error reading JSON file: {e}")
        
        time.sleep(delay)
    
    raise Exception("Jupyter server failed to start within the timeout period")

def setup_ssh_tunnel(hostname, username, key_filename, compute_node, remote_port, local_port):
    """Set up SSH tunnel in the background and return the process."""
    # First tunnel from local to login node, then from login node to compute node
    tunnel_cmd = [
        'ssh',
        '-N',  # Don't execute remote command
        '-L', f'{local_port}:{compute_node}:{remote_port}',  # Local port forwarding through login node
        '-i', key_filename,  # Use the same key file
        '-o', 'BatchMode=yes',  # Don't ask for password
        '-o', 'StrictHostKeyChecking=no',  # Don't ask about host keys
        '-o', 'ExitOnForwardFailure=yes',  # Exit if port forwarding fails
        '-o', 'ServerAliveInterval=60',  # Keep connection alive
        f'{username}@{hostname}'
    ]
    
    print(f"Setting up SSH tunnel with command: {' '.join(tunnel_cmd)}")
    
    # Start the tunnel process
    tunnel_process = subprocess.Popen(
        tunnel_cmd,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        universal_newlines=True
    )
    
    # Wait a moment to ensure the tunnel is established
    time.sleep(2)
    
    # Check tunnel process status
    if tunnel_process.poll() is not None:
        stdout, stderr = tunnel_process.communicate()
        print("SSH tunnel failed to start:")
        print("STDOUT:", stdout)
        print("STDERR:", stderr)
        raise Exception("SSH tunnel failed to start")
    
    # Check if the tunnel is working
    if check_port_availability(local_port):
        print(f"SSH tunnel is established and port {local_port} is available")
        
        # Try to verify the tunnel by checking if we can connect to the compute node
        try:
            verify_cmd = [
                'ssh',
                '-i', key_filename,
                '-o', 'BatchMode=yes',
                '-o', 'StrictHostKeyChecking=no',
                '-o', 'ConnectTimeout=5',
                f'{username}@{hostname}',
                f'nc -z {compute_node} {remote_port}'
            ]
            print(f"Verifying tunnel with command: {' '.join(verify_cmd)}")
            result = subprocess.run(verify_cmd, capture_output=True, text=True)
            if result.returncode == 0:
                print("Tunnel verification successful")
            else:
                print("Tunnel verification failed:", result.stderr)
        except Exception as e:
            print(f"Error verifying tunnel: {e}")
    else:
        print(f"Warning: Port {local_port} is not available. Tunnel may not be working.")
        # Get tunnel process output
        stdout, stderr = tunnel_process.communicate()
        print("Tunnel process output:")
        print("STDOUT:", stdout)
        print("STDERR:", stderr)
    
    return tunnel_process

def cleanup(tunnel_process):
    """Clean up the SSH tunnel process."""
    if tunnel_process:
        tunnel_process.terminate()
        tunnel_process.wait()

def main():
    # Get username and password from user input
    username = input('Enter your username: ')
    password = getpass.getpass(prompt='Enter your password: ')
    hostname = 'orcd-login001.mit.edu'
    tunnel_process = None

    try:
        # Get the list of SSH keys in the user's .ssh directory
        ssh_dir = os.path.expanduser(f'/Users/{username}/.ssh')
        ssh_keys = [f for f in os.listdir(ssh_dir) if f.endswith('.pub')]

        if not ssh_keys:
            print("No SSH keys found in the .ssh directory.")
            return

        print("Available SSH keys:")
        for i, key in enumerate(ssh_keys):
            print(f"{i + 1}: {key}")

        key_choice = int(input("Select the SSH key to use (enter the number): ")) - 1
        key_filename = os.path.join(ssh_dir, ssh_keys[key_choice].replace('.pub', ''))

        # Create an SSH client
        ssh = paramiko.SSHClient()

        # Load SSH host keys
        ssh.load_system_host_keys()

        # Add missing host keys
        ssh.set_missing_host_key_policy(paramiko.AutoAddPolicy())

        try:
            # Try connecting with the selected SSH key first
            ssh.connect(hostname=hostname, username=username, key_filename=key_filename)
            print(f"Successfully connected to {hostname} as {username} using SSH key.")
        except (paramiko.AuthenticationException, paramiko.SSHException) as e:
            print(f"SSH key authentication failed: {e}")
            try:
                # If SSH key fails, fall back to password authentication
                ssh.connect(hostname=hostname, port=22, username=username, password=password)
                print(f"Successfully connected to {hostname} as {username} using password.")
            except Exception as e:
                print(f"An error occurred: {e}")
                return

        try:
            # Get the home directory
            stdin, stdout, stderr = ssh.exec_command('echo $HOME')
            home_dir = stdout.read().decode().strip()
            
            # Open an SFTP session
            sftp = ssh.open_sftp()

            # Define the remote path for the submission script using the actual home directory
            remote_script_path = f'{home_dir}/submission_script.sh'

            # Create the submission script with the correct username
            submission_script = create_submission_script(username)

            # Write the submission script to the remote server
            with sftp.open(remote_script_path, 'w') as remote_file:
                remote_file.write(submission_script)

            # Close the SFTP session
            sftp.close()

            # Make the script executable
            ssh.exec_command(f'chmod +x {remote_script_path}')

            # Submit the job to Slurm
            stdin, stdout, stderr = ssh.exec_command(f'sbatch {remote_script_path}')
            job_output = stdout.read().decode()
            print(job_output)
            
            # Extract job ID from the output
            job_id_match = re.search(r'Submitted batch job (\d+)', job_output)
            if not job_id_match:
                print("Failed to get job ID from Slurm output")
                return
                
            job_id = job_id_match.group(1)
            print(f"Waiting for job {job_id} to start...")

            # Get the compute node where the job is running
            compute_node = get_compute_node(ssh, job_id)

            # Wait for the Jupyter server to be ready on the compute node
            json_content = wait_for_jupyter_server(ssh, home_dir)
            
            # Extract the host and port from the URL
            url = json_content['url']
            token = json_content['token']
            
            # Parse the remote host and port
            url_match = re.match(r'http://([^:]+):(\d+)', url)
            if url_match:
                remote_host = url_match.group(1)
                remote_port = int(url_match.group(2))
                local_port = remote_port  # Use the same port locally
                
                # Set up SSH tunnel through login node to compute node
                print(f"\nSetting up SSH tunnel from localhost:{local_port} to {compute_node}:{remote_port}")
                tunnel_process = setup_ssh_tunnel(hostname, username, key_filename, compute_node, remote_port, local_port)
                
                # Construct the local URL
                local_url = f'http://localhost:{local_port}/?token={token}'
                print(f"\nJupyterLab is ready!")
                print(f"Please open this URL in your browser: {local_url}")
                print(f"Token: {token}")
                
                # Open the browser with the local URL
                os.system(f'open {local_url}')
                
                print("\nJupyterLab is now running!")
                print("Press Ctrl+C to stop the SSH tunnel and exit.")
                print("Note: The JupyterLab server will continue running on the cluster for 3 hours.")
                
                # Keep the script running to maintain the tunnel
                while True:
                    time.sleep(1)
            else:
                print("Could not parse the Jupyter server URL.")

        finally:
            # Close the connection
            ssh.close()

    except KeyboardInterrupt:
        print("\nShutting down...")
    finally:
        cleanup(tunnel_process)

if __name__ == "__main__":
    main()
