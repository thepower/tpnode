**Table of Contents**

- [How to start a TP-Node from the source?](#how-to-start-a-tp-node-from-the-source)
  - [Setting up the environment](#setting-up-the-environment)
  - [Downloading and building the node](#downloading-and-building-the-node)
  - [Starting the node](#starting-the-node)
    - [Starting the node in Dev Mode](#starting-the-node-in-dev-mode)
    - [Starting the node in Release Mode](#starting-the-node-in-release-mode)

# How to start a TP-Node from the source?

TP-Node is the main module of The Power Ecosystem. In this manual, you'll learn how to start a node from the source code on Linux.

## Setting up the environment

Before you start your TP-Node, you need to set up the environment:

1. Check if you have Git installed:

   ```bash
   git version
   ```
2. If you don't have Git installed on your machine, run:

   ```bash
   apt install git
   ```

3. Install Erlang. To do this, download the `kerl` script

   ```bash
   curl -O https://raw.githubusercontent.com/kerl/kerl/master/kerl
   ```
   > **Note**
   >
   > If you already have Erlang installed on your machine, we strongly recommend deleting it before the new installation, using the following command:
   >
   > ```bash
   > apt purge erlang*
   > ```

4. Change script mode to executable by using the following command:

   ```bash
   chmod a+x kerl
   ```

5. Create a new directory in `/opt`. You can choose any name for this directory. Noteworthy is that the name should be descriptive for you:

   ```bash
   mkdir erlang
   ```
6. Update the list of Erlang releases using the following command:

   ```bash
   ./kerl update releases
   ```

7. Build the release 22.3.4.25 using the following command:

   ```bash
   ./kerl build 22.3.4.25
   ```


> **Important**
>
> You need to install Erlang ver. 22.3.4.25. Other versions may not work correctly.

After installation is complete, you will see the following message in the console:

   ```text
   Erlang/OTP 22.3.4.25 (22.3.4.25) has been successfully built
   ```

8. Install Erlang using the following command:

   ```bash
   ./kerl install 22.3.4.25 /opt/erlang
   ```

9. Run the following command to activate the Erlang installation:

   ```bash
   source /opt/erlang/activate
   ```

## Downloading and building the node

After setting up the working environment, you can download and build the node:

> **Note**
> 
> Choose a project folder to clone your project into. Use this folder to build the node.

1. Download the node sources from Github into your working directory (`your_node`, for instance), using the following command:

   ```bash
   git clone https://github.com/thepower/tpnode.git
   ```

2. Delete the previous builds (if present) in `/tpnode` by running the following command:

   ```bash
   rm -rf _build/default/*
   ```

3. Compile the node source by running the following command:

   ```bash
   ./rebar3 compile
   ```
4. Pack the compiled node into a `tar` by running the following command:

   ```bash
   ./rebar3 tar
   ```

   > **Note**
   >
   > This step is optional. `tar`-package is needed to quickly transfer the compiled source code. However, it can be a good option if you need to download the source manifold.

Now you can start the node.

## Starting the node

You can start a node in two different modes:

- Dev Mode. In this mode, you can start a node without building a release.
- Release Mode. In this mode, you must build the release before starting the node.

### Starting the node in Dev Mode

1. Before starting the node in Dev Mode, start a `tmux` session:

```bash
tmux
```

To start the node in Dev Mode, run:

```bash
./rebar3 shell
```
### Starting the node in Release Mode

1. Refer to section ["Downloading and building the node"](#downloading-and-building-the-node) above to build the node.
2. To start the node, run:

   ```bash
   ./bin/thepower foreground
   ```
