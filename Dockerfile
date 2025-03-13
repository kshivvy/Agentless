# Use Miniconda as the base image
FROM continuumio/miniconda3:latest

# Disable Python output buffering so logs are printed in real-time
ENV PYTHONUNBUFFERED=1

# Prevent Python from writing .pyc files to disk
ENV PYTHONDONTWRITEBYTECODE=1

# Update the package index so we can install the latest versions
RUN apt-get update

# Install git (required for Agentless operations like cloning repos)
RUN apt-get install -y git

# Set the working directory inside the container
WORKDIR /app

# Copy all files into the container
COPY . /app/

# Set PYTHONPATH to include the /app directory for module imports
ENV PYTHONPATH="/app"

# Create a Conda environment and activate it (just use base environment in this case)
# This installs Python and any dependencies defined in requirements.txt via pip
RUN conda create -y -n agentless python=3.11

# Initialize conda and install dependencies from the requirements.txt
RUN echo "source /opt/conda/etc/profile.d/conda.sh" >> ~/.bashrc && \
    /bin/bash -c "source /opt/conda/etc/profile.d/conda.sh && conda activate agentless && pip install --no-cache-dir -r requirements.txt"
    
# Set the default command to run the shell script inside the Conda environment
CMD ["bash", "/app/run_agentless.sh"]