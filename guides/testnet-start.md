**Table of Contents**

- [How to install and start a testnet?](#how-to-install-and-start-a-testnet)
  - [Testnet installation](#testnet-installation)
    - [Prerequisites](#prerequisites)
    - [Installation](#installation)
    - [Starting the testnet](#starting-the-testnet)
    - [Stopping the testnet](#stopping-the-testnet)
  - [Setting up the environment and starting the testnet using Vagrant](#setting-up-the-environment-and-starting-the-testnet-using-vagrant)
    - [Installation and setting up Vagrant](#installation-and-setting-up-vagrant)
    - [Setting up the environment](#setting-up-the-environment)
    - [Compiling and starting the node](#compiling-and-starting-the-node)
    - [Stopping the testnet](#stopping-the-testnet-1)
    - [Using Makefile targets](#using-makefile-targets)
    - [Using API](#using-api)

# How to install and start a testnet?

This manual describes how you can configure a testnet.

Here are some terms to start with:

- **Testnet**,
- **Test chain**.

These terms mean the same, except that you can form your testnet out of more than one chain.

## Testnet installation

> **Attention**
>
> This testnet uses preinstalled private keys for nodes. These keys are open and used for testing purposes only. Therefore, the testnet will be compromised when using it in a real-world system.

### Prerequisites

To start the testnet, ensure you have the following software installed on your machine:

- git,
- docker-compose.

> **Note**
> 
> If you use Unix, you must be included into the user group `docker` to use `docker-compose`.
>
> To check the groups, you are included into, run:
> 
> ```bash
> user@root:~$ groups
> ```
> To include your account into the group `docker`, run:
> 
> ```bash
> usermod + docker
> ```
> 
> This group is available only after you have installed Docker. If you haven't installed it yet, here is a [How-To](https://docs.docker.com/engine/install/). Go to the link and choose your OS.

### Installation

To install the testnet:

1. Clone the `test_chain` repository into your working directory using the following command:

   ```bash
   git clone https://github.com/thepower/test_chain.git
   ```

2. Go to `test_chain` directory:

   ```bash
   cd test_chain
   ```

### Starting the testnet

To start a testnet, run:

```bash
docker-compose up -d
```

After starting the testnet, node API is available under the following addresses:

```text
http://localhost:44001/api/status
http://localhost:44002/api/status
http://localhost:44003/api/status
```

To test your chain, run the following sequence of commands:

```bash
curl http://localhost:44001/api/node/status | jq
```

```bash
curl http://localhost:44001/api/block/last | jq
```

### Stopping the testnet

Please, stop your local testnet after completing all necessary testing or development. To stop the testnet, run:

```bash
docker-compose down
```

## Setting up the environment and starting the testnet using Vagrant

As an option, you can use Vagrant to setup development environment.

Here is an example of setting up the development environment for MacOS.

### Installation and setting up Vagrant

To set up Vagrant, follow the steps below:

1. Install vagrant:

   ```bash
   brew install caskroom/cask/vagrant
   ```

2. If you use a VM:

   1. For Parallels, add Parallels support to Vagrant:

      ```bash
      vagrant plugin install vagrant-parallels
      ```

   2. For VirtualBox (default option), modify the `PATH` variable to add the VirtualBox binary to Vagrant:

      ```bash
      export PATH=/Applications/VirtualBox.app/Contents/MacOS:$PATH
      ```

3. Install the hostmanager plugin to manage the `/etc/hosts` file:

   ```bash
   vagrant plugin install vagrant-hostmanager
   ```

### Setting up the environment

To set up the environment, follow the steps below:

1. Clone the `tpnode` repository from Github and go to `tpnode` directory.

2. Start the virtual machine using Vagrant:

   ```bash
   vagrant up
   ```

   > **Attention**
   >
   > When running the Vagrant command, provisioning will be started. During the provisioning, Vagrant downloads all the necessary libraries and compiles the proper versions of Erlang and other environment components.Reboot the virtual machine after successful provisioning using the following commands:
   >
   > ```bash
   > vagrant halt
   > ```
   >
   > ```bash
   > vagrant up
   > ```

3. Connect to virtual environment by running:

   ```bash
   vagrant ssh -- -A
   ```

   where:

   - `-A` — key to ssh agent forwarding. You will be able to use ssh key from host machine to perform operations inside the virtual machine.

### Compiling and starting the node

1. Go to the project directory:

   ```bash
   cd /vagrant
   ```

2. Compile the testnet by running the following command:

   ```bash
   make buildtest
   ```

3. Start the testnet by running the script:

   ```bash
   ./bin/testnet.sh
   ```
### Stopping the testnet

To stop the testnet, run:

```bash
./bin/testnet.sh stop
```

### Using Makefile targets

You can also use the Makefile targets as a reference on how to perform other tasks.

### Using API

You can see the API ports by running:

```bash
netstat -an |grep 498
```

> **Note**
>
> After you've started testnet you should see 9 different ports. You can use these ports for The Power nodes API calls.
>
> API call sample:
>
> ```bash
> curl http://pwr.local:49841/api/node/status | jq .
> ```
>
> Note: the domain `pwr.local` in URL is used to reference the node from virtual or host machine.
