# MIT ORCD JupyterLab Launcher

This script helps you launch a JupyterLab session on MIT's ORCD computing cluster. It handles:
- SSH connection to the login node
- Slurm job submission
- JupyterLab server startup
- SSH tunnel setup for local access

## Prerequisites

1. **Python Environment**:
   ```bash
   # Create a new conda environment
   conda create -n paramiko-connect python=3.9
   conda activate paramiko-connect
   
   # Install required packages
   pip install paramiko
   ```

2. **SSH Key Setup**:
   ```bash
   # Generate an SSH key if you don't have one
   ssh-keygen -t ed25519 -C "your_email@example.com"
   
   # Add your public key to the cluster
   cat ~/.ssh/id_ed25519.pub | ssh your_username@orcd-login001.mit.edu "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
   ```

## Usage

1. Activate the conda environment:
   ```bash
   conda activate paramiko-connect
   ```

2. Run the script:
   ```bash
   python test-paramiko.3.py
   ```

3. Follow the prompts:
   - Enter your MIT username
   - Enter your password (only needed for initial connection)
   - Select your SSH key

4. The script will:
   - Connect to the login node
   - Submit a Slurm job
   - Start JupyterLab on a compute node
   - Set up an SSH tunnel
   - Open your browser to the JupyterLab interface

## Troubleshooting

1. **SSH Key Issues**:
   - Make sure your SSH key is in `~/.ssh/`
   - Verify the key is added to the server's `authorized_keys`
   - Check key permissions: `chmod 600 ~/.ssh/id_ed25519`

2. **Connection Issues**:
   - Verify you can SSH to the login node: `ssh your_username@orcd-login001.mit.edu`
   - Check if the port (8874) is available on your machine
   - Look for error messages in the script output

3. **JupyterLab Issues**:
   - Check the job status: `ssh your_username@orcd-login001.mit.edu "squeue -u your_username"`
   - View job output: `ssh your_username@orcd-login001.mit.edu "cat combined.txt"`

## Notes

- The JupyterLab session will run for 3 hours
- You can disconnect and reconnect to the session during this time
- The SSH tunnel must remain active to access JupyterLab
- Press Ctrl+C to stop the script and close the tunnel 