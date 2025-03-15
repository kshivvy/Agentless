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

# Git config is needed to run "git commit" during postprocessing.
RUN git config --global user.email "johndoe@google.com" && \
    git config --global user.name "John Doe"

# Set the working directory inside the container
WORKDIR /app

# Download cached files.
RUN mkdir -p /app/data && \
    curl -o /app/data/swebench_lite_repo_structure.zip -L https://github.com/OpenAutoCoder/Agentless/releases/download/v0.1.0/swebench_lite_repo_structure.zip && \
    unzip /app/data/swebench_lite_repo_structure.zip -d /app/data

# Set PYTHONPATH to include the /app directory for module imports
ENV PYTHONPATH="/app"

# Create a Conda environment and activate it (just use base environment in this case)
# This installs Python and any dependencies defined in requirements.txt via pip
RUN conda create -y -n agentless python=3.11

ENV PATH="/opt/conda/envs/agentless/bin:$PATH"

# Copy requirements.txt file first as we need to 
COPY requirements.txt .

# Initialize conda and install dependencies from the requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

ENV PROJECT_FILE_LOC=/app/data/repo_structures

# Copy rest of the files into the container
COPY . /app/

# Set the default command to run the shell script inside the Conda environment
CMD ["bash", "/app/run.sh"]
