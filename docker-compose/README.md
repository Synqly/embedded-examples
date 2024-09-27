# Run Synqly Embedded with Docker Compose

## Setup

**NOTE:** This assumes that `docker compose` is installed. For more information, see the [installation instructions](https://docs.docker.com/compose/install/).

This compose file also expects a local data directory to persist the database between docker-compose runs.
This directory can be any directory that's a valid mountable directory for docker.
If you change the directory path, make sure to update
`services.embedded-database.volumes[0]` in the docker-compose file you are using.

Synqly Embedded is compatible with any PostgreSQL compatible database, this
directory contains docker-compose examples for both CockroachDB and Postgres.

Decide which database you'd like to run with, then create a local directory by running the following:

### CockroachDB
```
mkdir -p ~/demo-apps/embedded-cockroachdb
```

### Postgres
```
mkdir -p ~/demo-apps/embedded-postgres
```

Update the local DB user and password in `.env` to non default values:
```txt
DB_USER=<new-user>
DB_PASS=<new-password>
```

## First Run

Run Synqly Embedded with the following command:

### CockroachDB

```shell
docker compose -f synqly-embedded-cockroachdb.yaml up
```

### Postgres

```shell
docker compose -f synqly-embedded-postgres.yaml up
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

## Embedded Address

Once all of the containers have booted, Synqly Embedded APIs will be available
at `http://localhost:9000`. 

To quickly test whether Embedded is running as expected, run the following command
to fetch the build version:
```bash
curl localhost:9000/v1/version
```

The response should resemble the following:
```bash
{"commit":"e5b1522f","date":"Fri Sep 27 16:30:56 UTC 2024","go_version":"go version go1.22.7 linux/amd64","version":"20240927.1629.01-e5b1522"}%
```

## Run a Single Service

To run a single service only (such as the database):

```shell
docker compose -f synqly-embedded-compose.yaml up embedded-database
```

## Wipe Local Data

### CockroachDB

Use the following commands to reset the local data directory:
```bash
# Wipe local database storage
rm -rf ~/demo-apps/embedded-cockroachdb

# Re-initialize local storage
mkdir -p ~/demo-apps/embedded-cockroachdb
```

### Postgres

```bash
# Wipe local database storage
rm -rf ~/demo-apps/embedded-postgres

# Re-initialize local storage
mkdir -p ~/demo-apps/embedded-postgres
```