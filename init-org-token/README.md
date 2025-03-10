# Init Organization Token Utility

## Overview

The `init-org.py` script is a utility designed to initialize or reset organization tokens for Synqly Embedded. This script automates the process of retrieving organization details, authenticating as an admin user, and generating new access and refresh tokens for a Synqly organization.

Note that this script makes use of the private API endpoints that run on a separate port from the public API. These run on port `9000` and you must ensure that this port is exposed and accessible. See the [docker-compose example README](../docker-compose/README.md) for more details.

## Requirements

- Python 3.6+
- `requests` library (pip install requests)
- A running Synqly Embedded service
- Proper environment variables configuration

## Configuration

The script uses environment variables for configuration. The provided `.env` file shows the required variables. The values used here must match the values you started the Synqly Embedded service with. See the [docker-compose example README](../docker-compose/README.md) for more details.

## Usage

Make sure your Synqly Embedded service is running and has the private API exposed through a separate port. The default in the docker-compose example is `http://localhost:9001`; for production, this endpoint should not be exposed publicly and so you would need to use a tool like kube-proxy or private service to access it.

Export the environment variables from the `.env` file:

```bash
export $(xargs < .env)
```

And then run the script:

```bash
python3 init-org.py
```
