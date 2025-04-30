import paramiko
import getpass
import json
import os
import time

# Define the submission script as a string
submission_script = """#!/bin/bash
#SBATCH --job-name=test_job
#SBATCH --output=output.txt
#SBATCH --error=error.txt
#SBATCH --time=01:00:00
#SBATCH --partition=standard

echo "Running job on $(hostname)"
"""

def main():
    # Get username and password from user input
    username = input('Enter your username: ')
    password = getpass.getpass(prompt='Enter your password: ')
    hostname = 'orcd-login001.mit.edu'

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
        # Try connecting with the selected SSH key
        ssh.connect(hostname=hostname, username=username, key_filename=key_filename)
        print(f"Successfully connected to {hostname} as {username} using SSH key.")
    except (paramiko.AuthenticationException, paramiko.SSHException) as e:
        print(f"SSH key authentication failed: {e}")
        try:
            # If SSH key fails, connect using password
            ssh.connect(hostname=hostname, port=22, username=username, password=password)
            print(f"Successfully connected to {hostname} as {username} using password.")
        except Exception as e:
            print(f"An error occurred: {e}")
            return

    try:
        # Open an SFTP session
        sftp = ssh.open_sftp()

        # Define the remote path for the submission script using $HOME
        remote_script_path = '$HOME/submission_script.sh'

        # Write the submission script to the remote server
        with sftp.open(remote_script_path, 'w') as remote_file:
            remote_file.write(submission_script)

        # Close the SFTP session
        sftp.close()

        # Make the script executable
        ssh.exec_command(f'chmod +x {remote_script_path}')

        # Submit the job to Slurm
        stdin, stdout, stderr = ssh.exec_command(f'sbatch {remote_script_path}')
        print(stdout.read().decode())

        # Wait for the job to complete (you may need to adjust the sleep time)
        time.sleep(60)

        # Read the contents of the directory $HOME/.local/share/jupyter/runtime
        runtime_dir = '.local/share/jupyter/runtime'
        stdin, stdout, stderr = ssh.exec_command(f'ls -t $HOME/{runtime_dir}/jpserver-*.json')
        files = stdout.read().decode().split()

        if files:
            newest_file = files[0]
            print(f'Newest JSON file: {newest_file}')

            # Read the contents of the newest JSON file
            sftp = ssh.open_sftp()
            with sftp.open(f'$HOME/{runtime_dir}/{newest_file}', 'r') as remote_file:
                json_content = json.load(remote_file)

            # Construct the command to open the browser
            url = json_content['url']
            token = json_content['token']
            full_url = f'{url}?token={token}'
            open_browser_command = f'open {full_url}'
            print(f'Command to open browser: {open_browser_command}')

            # Execute the command to open the browser on the client machine
            os.system(open_browser_command)

        else:
            print('No JSON files found.')

    finally:
        # Close the connection
        ssh.close()

if __name__ == "__main__":
    main()
