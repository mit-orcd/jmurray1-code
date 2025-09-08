#!/bin/bash

# Determine the architecture
ARCH=$(uname -m)

# Set the Miniforge installer URL based on the architecture
if [ "$ARCH" == "x86_64" ]; then
    MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-x86_64.sh"
elif [ "$ARCH" == "arm64" ]; then
    MINIFORGE_URL="https://github.com/conda-forge/miniforge/releases/latest/download/Miniforge3-MacOSX-arm64.sh"
else
    echo "Unsupported architecture: $ARCH"
    exit 1
fi

# Download the Miniforge installer
echo "Downloading Miniforge installer for $ARCH..."
curl -L -o Miniforge3-MacOSX.sh $MINIFORGE_URL

# Make the installer executable
chmod +x Miniforge3-MacOSX.sh

# Run the installer
echo "Running Miniforge installer..."
./Miniforge3-MacOSX.sh -b

# Initialize Conda
echo "Initializing Conda..."
source ~/miniforge3/bin/conda init

# Notify the user
echo "Miniforge installation complete. Conda is now initialized."

