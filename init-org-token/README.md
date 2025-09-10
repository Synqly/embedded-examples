# Init Organization Token Utility

## Overview

The `init-org.py` script is a utility designed to initialize or reset organization tokens for Synqly Embedded. This script automates the process of, authenticating as an admin user, retrieving organization details, and generating new access and refresh tokens for a Synqly organization.

## Requirements

- Python 3.6+
- `requests` library (pip install requests)
- A running Synqly Embedded service
- Proper environment variables configuration

## Configuration

The script uses environment variables for configuration. The provided `.env` file shows the required variables. The values used here must match the values you started the Synqly Embedded service with. See the [docker-compose example README](../docker-compose/README.md) for more details.

## Usage

Make sure your Synqly Embedded service is running and has the API exposed. The default in the docker-compose example is `http://localhost:8000`.

Export the environment variables from the `.env` file:

```bash
export $(xargs < .env)
```

And then run the script:

```bash
python3 init-org.py
```
