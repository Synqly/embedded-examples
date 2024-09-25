# Run Synqly Embedded with Docker Compose

## Setup

**NOTE:** This assumes that `docker compose` is installed. For more information, see the [installation instructions](https://docs.docker.com/compose/install/).

This compose file also expects a local data directory to persist the database between docker-compose runs.
This directory can be any directory that's a valid mountable directory for docker.
If you change the directory path, make sure to update it in `synqly-embedded-compose.yaml`
at `services.embedded-database.volumes[0]`.

Create a local directory by running the following:
```
mkdir -p ~/demo-apps/embedded-local-db
```

## First Run

Run Synqly embedded by running the following command:

```shell
docker compose -f synqly-embedded-compose.yaml up
```

This will take a few minutes the first time running things while the images
download and database initializes.

On the first docker-compose run, Embedded will generate a Synqly Organization and
print the organization details to the docker compose logs. Copy this information
somewhere durable. 

The token listed under `organization.token.access.secret` is an
Organization token. It can be used to start running Management API calls, such 
as to [Create an Account](https://docs.synqly.com/reference/accounts_create).

```bash
embedded-1           | {"level":"info","address":"localhost:9000","time":"2024-09-25T15:17:15Z","message":"starting management"}
embedded-1           | {"level":"info","time":"2024-09-25T15:17:16Z","message":"status pods: [http://localhost:9002], http://."}
embedded-1           | {"level":"info","address":"localhost:9001","time":"2024-09-25T15:17:16Z","message":"starting engine"}
embedded-1           | {"level":"info","address":"localhost:9002","time":"2024-09-25T15:17:16Z","message":"starting status"}
embedded-1           | {"level":"info","address":"localhost:9003","time":"2024-09-25T15:17:16Z","message":"starting hooks"}
embedded-1           | {"level":"info","address":"0.0.0.0:9040","time":"2024-09-25T15:17:16Z","message":"starting gateway"}
embedded-1           | {"level":"error","error":"Not Found","root_organization":"6f4afac8-44ff-40ee-80b7-c27cd16e5e8d","organization":"embedded","time":"2024-09-25T15:17:17Z","message":"find organization failed"}
embedded-1           | organization: {
embedded-1           |   "organization": {
embedded-1           |     "name": "embedded",
embedded-1           |     "id": "28d63688-ece5-41db-b70c-6c7d0111a5e8",
embedded-1           |     "refresh_token_id": "a10d4ec4-55a0-43aa-9f72-a4b5cb017958",
embedded-1           |     "organization_type": "standard",
...
```

## Run a Single Service

To run a single service only (such as the database):

```shell
docker compose -f synqly-embedded-compose.yaml up embedded-database
```

## Wipe Local Data

Use the following commands to reset the local data directory:
```bash
# Wipe local database storage
rm -rf ~/demo-apps/embedded-local-db

# Re-initialize local storage
mkdir -p ~/demo-apps/embedded-local-db
```