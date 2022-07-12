**Table of Contents**

- [How to start a TP-Node from a Docker image?](#how-to-start-a-tp-node-from-a-docker-image)
  - [Setting up the environment](#setting-up-the-environment)
  - [Starting the node](#starting-the-node)

# How to start a TP-Node from a Docker image?

You can start a TP-Node using the [Docker image](https://hub.docker.com/r/thepowerio/tpnode).

## Setting up the environment

Before you start a TP-Node using the Docker image:

1. Ensure you have Docker installed on your machine.
2. If not, refer to [Docker Installation Guide](https://docs.docker.com/engine/install/).
3. Check user groups you belong to by running the following command:

   ```bash
   $ groups
   ```
4. If you don't belong to the user group `docker`, you will not be able to start Docker. To resolve this problem, run:

   ```bash
   # usermod -a docker
   ```

5. Ensure you have the actual `genesis.txt` and `node.config` files.
6. Create `db` and `log` directories in your working directory (`/opt`, for instance).

   > **Hint**
   >
   > You can create an additional directory named `thepower`, for example, and place `db` and `log` as subdirectories there.

7. Place the files `genesis.txt` and `node.config` near `db` and `log` directories.

## Starting the node

To start the TP-Node run the following command:

```bash
docker run -d \
--name tpnode \
--mount type=bind,source="$(pwd)"/db,target=/opt/thepower/db \
--mount type=bind,source="$(pwd)"/log,target=/opt/thepower/log \
--mount type=bind,source="$(pwd)"/node.config,target=/opt/thepower/node.config \
--mount type=bind,source="$(pwd)"/genesis.txt,target=/opt/thepower/genesis.txt \
-p 43292:43292 \
-p 43392:43392 \
-p 43219:43219 \
thepowerio/tpnode
```

where:

| Command                                                                          | Description                                                                                                                                                 |
|----------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `docker run -d`                                                                  | This command starts Docker in the background                                                                                                                |
| `--name tpnode`                                                                  | This command specifies the name (optional)                                                                                                                  |
| `--mount type=bind,source="$(pwd)"/db,target=/opt/thepower/db`                   | Path to the database. Bound to Docker. `/opt` here is mandatory, because it is the path inside the container.                                               | 
| `--mount type=bind,source="$(pwd)"/log,target=/opt/thepower/log`                 | Path to log files. Bound to Docker. `/opt` here is mandatory, because it is the path inside the container.                                                  |
| `--mount type=bind,source="$(pwd)"/node.config,target=/opt/thepower/node.config` | Path to your `node.config` file. Bound to Docker. `/opt` here is mandatory, because it is the path inside the container.                                                                                                          |
| `--mount type=bind,source="$(pwd)"/genesis.txt,target=/opt/thepower/genesis.txt` | Path to your `genesis.txt`. Bound to Docker. `/opt` here is mandatory, because it is the path inside the container.                                                                                                                 |
| `-p 43292:43292` <br /> `-p 43392:43392` <br /> `-p 43219:43219`                 | These commands specify all necessary local ports. In this examples ports `api`, `apis`, and `tpic` are used. You can specify any port in `node.config` file |
| `thepowerio/tpnode`                                                              | Path to Docker image.                                                                                               |