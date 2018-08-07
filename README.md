# The Power Node

## Node Setup

We use vagrant to setup development environment. Here is an example of setting up a development environment on MacOS

### Prerequisites

1. Install vagrant: `brew install caskroom/cask/vagrant`
2. If you are using the Parallels for virtualization, please add it's support to vagrant: `vagrant plugin install vagrant-parallels`
3. If you are using the VirtualBox for virtualization (this is default option), you may want to modify the PATH variable to show vagrant the VirtualBox binary: `export PATH=/Applications/VirtualBox.app/Contents/MacOS:$PATH`
4. We use the hostmanager plugin to manage the /etc/hosts file. Please, install this plugin: `vagrant plugin install vagrant-hostmanager`

### Set up the environment

1. Please, clone this repository and get to it's directory.
2. Start the virtual machine using vagrant: `vagrant up`

   At the first time you run the vagrant command it will run the provisioning. It will be downloaded all necessary libraries, compiled proper version of erlang, etc. You have to reboot the virtual machine after successful provisioning (`vagrant halt; vagrant up`).

3. Please, get into virtual environment. `vagrant ssh -- -A`  (We use the -A key to ssh agent forwarding. So, for operations inside the virtual machine, you will be able to use your ssh key from host machine.)
4. `cd /vagrant`

At this point you are in the project directory. 

To compile the testnet use command: `make buildtest`

To run the testnet please use the script `./bin/testnet.sh`:

* start the testnet: `./bin/testnet.sh start`
* stop the testnet: `./bin/testnet.sh stop`

Please, also consult the Makefile targets as reference how to make other different tasks. 

You can see the API ports using the command: `netstat -an |grep 498` (After testnet was started you should see 9 different ports. You can use these ports for API calls of The Power nodes.)

Example API call:

```bash
curl http://pwr.local:49841/api/node/status | jq .
```

Please note, you may use the domain `pwr.local` in URL to reference the node from virtual machine or from host machine.

