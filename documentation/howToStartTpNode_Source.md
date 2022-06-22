# How to start a TP-Node from source?

TP-Node is the main module of The Power Ecosystem. In this manual you'll learn, how to start a node from the source code on Linux.

## Setting up the environment

Before you start your TP-Node, you need to set up the environment:

1. Check, if you have Git installed:
    
   ```bash
   git version
   ```
2. If Git is not installed on your machine, run:
    
   ```bash
   apt install git
   ```
   
3. Install Erlang. To do this, download the `kerl` script

   ```bash
   curl -O https://raw.githubusercontent.com/kerl/kerl/master/kerl
   ```
   > **Note**
   > 
   > If you already have Erlang installed on your machine, we strongly recommend to delete it before the new installation, using the following command:
   >
   > ```bash
   > apt purge erlang*
   > ```
   
4. Change script mode to executable by using the following command:

   ```bash
   chmod a+x kerl
   ```

5. Create a new directory in `/opt`. You can choose any name for this directory. Important is that the name should be descriptive for you:

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
   
   After installation is completed, you will see following message in the console:

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

After you've set up the working environment, you can download and build the node.

1. Download the node sources from Github, using the following command:

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
   > This step is optional. `tar`-package is needed to easily transfer the compiled source code. It can be a good option, if you need to download the source manyfold.

Now you can start the node.

## Starting the node

To start the node, run:

```bash
./bin/testnet.sh start
```

To reset the node, run:

```bash
./bin/testnet.sh reset
```