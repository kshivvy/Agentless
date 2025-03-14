# Use Miniconda as the base image
FROM continuumio/miniconda3:latest

# Disable Python output buffering so logs are printed in real-time
ENV PYTHONUNBUFFERED=1

# Prevent Python from writing .pyc files to disk
ENV PYTHONDONTWRITEBYTECODE=1

# Update the package index so we can install the latest versions
RUN apt-get update

# Install git (required for Agentless operations like cloning repos)
RUN apt-get install -y git unzip curl

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

RUN mkdir -p /app/data && \
    curl -o /app/data/agentless_swebench_lite.zip -L https://github.com/OpenAutoCoder/Agentless/releases/download/v1.5.0/agentless_swebench_lite.zip && \
    unzip /app/data/agentless_swebench_lite.zip -d /app/data

RUN curl -o /app/data/swebench_lite_repo_structure.zip -L https://github.com/OpenAutoCoder/Agentless/releases/download/v0.1.0/swebench_lite_repo_structure.zip && \
    unzip /app/data/swebench_lite_repo_structure.zip -d /app/data

ENV PROJECT_FILE_LOC=/app/data/swebench_lite_repo_structure/repo_structure

# Set the default command to run the shell script inside the Conda environment
CMD ["bash", "/app/run.sh"]
