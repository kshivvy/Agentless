FROM google/cloud-sdk:slim AS gs_download

WORKDIR /app

RUN apt-get update && \
    apt-get install -y --no-install-recommends unzip && \
    rm -rf /var/lib/apt/lists/*

# Download the precomputed data from google cloud.
RUN mkdir -p /app/data
RUN gsutil cp gs://agentless-precomputed/swebench_repo_structure.zip /tmp/downloaded.zip
RUN unzip /tmp/downloaded.zip -d /app/data
RUN rm /tmp/downloaded.zip

# Use Miniconda as the base image
FROM continuumio/miniconda3:latest AS app

COPY --from=gs_download /app/data /app/data

# Disable Python output buffering so logs are printed in real-time
ENV PYTHONUNBUFFERED=1

# Prevent Python from writing .pyc files to disk
ENV PYTHONDONTWRITEBYTECODE=1

# Update the package index so we can install the latest versions
RUN apt-get update && \
    apt-get install -y --no-install-recommends git && \
    rm -rf /var/lib/apt/lists/*

# Git config is needed to run "git commit" during postprocessing.
RUN git config --global user.email "johndoe@google.com" && \
    git config --global user.name "John Doe"

# Set the working directory inside the container
WORKDIR /app

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

ENV PROJECT_FILE_LOC=/app/data/repo_structure/repo_structures

# Copy rest of the files into the container
COPY . /app/

# Set the default command to run the shell script inside the Conda environment
CMD ["bash", "/app/run.sh"]
