# How to start a TP-Node from a Docker image?

You can start a TP-Node using the [Docker image](https://hub.docker.com/r/thepowerio/tpnode_evm).

## Setting up the environment

Before you start a TP-Node using the Docker image:

1. Ensure you have Docker installed on your machine.
2. If not, refer to [Docker Installation Guide](https://docs.docker.com/engine/install/)
3. Ensure you have the actual `genesis.txt` and `node.config` files.
4. Create `db` and `log` directories in `/opt`.
   
   > **Hint**
   > 
   > You can create an additional directory named `thepower`, for example, and place `db` and `log` as subdirectories there.

5. Place the files `genesis.txt` and `node.config` near `db` and `log` directories.

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
thepowerio/tpnode_evm:v0.10.1
```

where:

| Command                                                                                                                                                           | Description                                                                                                                                                 |
|-------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `docker run -d`                                                                                                                                                   | This command starts Docker in the background                                                                                                                |
| `--name tpnode`                                                                                                                                                   | This command specifies the name (optional)                                                                                                                  |
| `--mount type=bind,source="$(pwd)"/db,target=/opt/thepower/db`                                                                                                    | Path to the database. Bound to Docker                                                                                                                       | 
| `--mount type=bind,source="$(pwd)"/log,target=/opt/thepower/log`                                                                                                  | Path to log files. Bound to Docker                                                                                                                                           |
| `--mount type=bind,source="$(pwd)"/node.config,target=/opt/thepower/node.config`| Path to your `node.config` file. Bound to Docker                                                                                                                             |
| `--mount type=bind,source="$(pwd)"/genesis.txt,target=/opt/thepower/genesis.txt` | Path to your `genesis.txt`. Bound to Docker                                                                                                                                  |
| `-p 43292:43292` <br> `-p 43392:43392` <br> `-p 43219:43219`                                                                                                      | These commands specify all necessary local ports. In this examples ports `api`, `apis`, and `tpic` are used. You can specify any port in `node.config` file |
| `thepowerio/tpnode_evm:v.0.10.1`                                                                                                                                  | Path to Docker image. You need to specify the TP-Node version                                                                                               |
 