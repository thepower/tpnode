# Power_node

Power_node supports dev and release launch modes and require genesis and node.config files.

## Node.config

```config
%% -*- mode: erlang -*-

{tpic, #{ peers => [{"c105n2.thepower.io", 49903},{"c105n3.thepower.io", 49903},{"c105n4.thepower.io", 49903}.....], port => 49903} }.
{discovery,
    #{
        addresses => [
            #{address => "c105n1.thepower.io", port => tpicport, proto => tpic},
            #{address => "c105n1.thepower.io", port => rpcport, proto => api}
        ]
    }
}.

{hostname, "c105n1.thepower.io"}.
{rpcsport, 49741}.
{rpcport, 49841}.
{vmport, 29841}.
```

{crosschain, #{ port => 49741, connect => [ {"c106n1.thepower.io", 49741} ] }}.

{privkey, "key"}.

## Generator of genesis and node.config

Open Erlang console and run the command:

```erlang
genesis_easy:make_example(105,10).
```

Where:

`105` - shard number

`10` - number of nodes in shard

```erlang
genesis_easy:make_genesis(105).
```

Where:

`105` - shard number

### Genesis

The genesis will be saved in the `easy_chain105_genesis.txt` file.

```erlang
#{bals => #{},etxs => [],failed => [],
  hash =>
      <<>>,
  header =>
      #{chain => 105,height => 0,
        parent => <<0,0,0,0,0,0,0,0>>,
        roots =>
            [{setroot,<<>>}],
        ver => 2},
  settings =>
      [{<<"">>,
        #{body =>
              <<>>,
          kind => patch,
          patches =>
              [#{<<"p">> => [<<"chains">>],
                 <<"t">> => <<"list_add">>,<<"v">> => 105},
               #{<<"p">> => [<<"keys">>,<<"c105n1">>],
                 <<"t">> => <<"set">>,
                 <<"v">> =>
                     <<>>},
               #{<<"p">> => [<<"keys">>,<<"c105n10">>],
                 <<"t">> => <<"set">>,
                 <<"v">> =>
                     <<>>},
               #{<<"p">> => [<<"keys">>,<<"c105n2">>],
                 <<"t">> => <<"set">>,
                 <<"v">> =>
                     <<>>},
               #{<<"p">> => [<<"keys">>,<<"c105n3">>],
                 <<"t">> => <<"set">>,
                 <<"v">> =>
                     <<>>},
               #{<<"p">> => [<<"keys">>,<<"c105n4">>],
                 <<"t">> => <<"set">>,
                 <<"v">> =>
                     <<>>},
               #{<<"p">> => [<<"keys">>,<<"c105n5">>],
                 <<"t">> => <<"set">>,
                 <<"v">> =>
                     <<>>},
               #{<<"p">> => [<<"keys">>,<<"c105n6">>],
                 <<"t">> => <<"set">>,
                 <<"v">> =>
                     <<>>},
               #{<<"p">> => [<<"keys">>,<<"c105n7">>],
                 <<"t">> => <<"set">>,
                 <<"v">> =>
                     <<>>},
               #{<<"p">> => [<<"keys">>,<<"c105n8">>],
                 <<"t">> => <<"set">>,
                 <<"v">> =>
                     <<>>},
               #{<<"p">> => [<<"keys">>,<<"c105n9">>],
                 <<"t">> => <<"set">>,
                 <<"v">> =>
                     <<>>},
               #{<<"p">> => [<<"nodechain">>,<<"c105n1">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"nodechain">>,<<"c105n10">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"nodechain">>,<<"c105n2">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"nodechain">>,<<"c105n3">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"nodechain">>,<<"c105n4">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"nodechain">>,<<"c105n5">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"nodechain">>,<<"c105n6">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"nodechain">>,<<"c105n7">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"nodechain">>,<<"c105n8">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"nodechain">>,<<"c105n9">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"current">>,<<"chain">>,<<"blocktime">>],
                 <<"t">> => <<"set">>,<<"v">> => 3},
               #{<<"p">> => [<<"current">>,<<"chain">>,<<"minsig">>],
                 <<"t">> => <<"set">>,<<"v">> => 6},
               #{<<"p">> => [<<"current">>,<<"chain">>,<<"allowempty">>],
                 <<"t">> => <<"set">>,<<"v">> => 0},
               #{<<"p">> => [<<"current">>,<<"chain">>,<<"patchsigs">>],
                 <<"t">> => <<"set">>,<<"v">> => 6},
               #{<<"p">> => [<<"current">>,<<"allocblock">>,<<"block">>],
                 <<"t">> => <<"set">>,<<"v">> => 105},
               #{<<"p">> => [<<"current">>,<<"allocblock">>,<<"group">>],
                 <<"t">> => <<"set">>,<<"v">> => 10},
               #{<<"p">> => [<<"current">>,<<"allocblock">>,<<"last">>],
                 <<"t">> => <<"set">>,<<"v">> => 0},
               #{<<"p">> =>
                     [<<"current">>,<<"endless">>,
                      <<>>,
                      <<"SK">>],
                 <<"t">> => <<"set">>,<<"v">> => true},
               #{<<"p">> =>
                     [<<"current">>,<<"endless">>,
                      <<>>,
                      <<"TST">>],
                 <<"t">> => <<"set">>,<<"v">> => true},
               #{<<"p">> => [<<"current">>,<<"freegas">>],
                 <<"t">> => <<"set">>,<<"v">> => 2000000},
               #{<<"p">> => [<<"current">>,<<"gas">>,<<"SK">>],
                 <<"t">> => <<"set">>,<<"v">> => 1000},
               #{<<"p">> => [<<"current">>,<<"nosk">>],
                 <<"t">> => <<"set">>,<<"v">> => 1}],
          sig =>
              [],
          ver => 2}}],
  sign =>
      [],
  txs => []}.
```

Genesis specifies `minsig` and `patchsig`:

`minsig` - the minimum number of signatures for consensus in the shard.

`patchsig` - minimum number of signatures for a shard patch transaction.

Copy genesists to all hosts as `genesis.txt`.

### Node private keys

Сopy private keys to `node.config` from file `easy_chain105_keys.txt`

For each node the corresponding privkey.

The keys of others will be in genesis.

## Recomended environment

`Ubuntu 18.04.5 LTS`

`Erlang/OTP 22`

`Eshell V10.4`

## Datababase

Please create a folder for the database in the folder of dev `/` or release:

```bash
mkdir db
```

## DevMode start

We recommend using sessions in `tmux` in order to work comfortably in development mode

```bash
tmux
```

When `tmux` session is started, run the command:

```bash
./rebar3 shell
```

## Build release

When you make databese directory, run the command:

```bash
JSX_FORCE_MAPS=1 ./rebar3 compile
```

## Release start

Power_node start:

```bash
./bin/thepower foreground
```

Help commands:

```bash
./bin/thepower
```

## Build docker image

Please put the `Dockerfile` in the release directory and run the command:

```bash
docker run -t power-node .
```

## Docker power_node start

```bash
docker run -v /opt/tpnode/db:/opt/thepower/db -p 49841:49841 -p 29841:29841 -p 49903:49903 power_node foreground .
```

## Local testnet launch

We use vagrant to setup development environment. Here is an example of setting up a development environment on MacOS

### Prerequisites

1. Install vagrant:

```bash
brew install caskroom/cask/vagrant
```

2. If you are using the Parallels for virtualization, please add it's support to vagrant:

```bash
vagrant plugin install vagrant-parallels
```

3. If you are using the VirtualBox for virtualization (this is default option), you may want to modify the `PATH` variable to show vagrant the VirtualBox binary:

```bash
export PATH=/Applications/VirtualBox.app/Contents/MacOS:$PATH
```

4. We use the hostmanager plugin to manage the `/etc/hosts` file. Please, install this plugin:

```bash
vagrant plugin install vagrant-hostmanager
```

### Set up the environment

1. Please, clone this repository and get to it's directory.

2. Start the virtual machine using vagrant:

```bash
vagrant up
```

At the first time you run the vagrant command it will run the provisioning. It will be downloaded all necessary libraries, compiled proper version of erlang, etc. You have to reboot the virtual machine after successful provisioning

```bash
vagrant halt
```

```bash
vagrant up
```

3. Please, get into virtual environment.

```bash
vagrant ssh -- -A
```

(We use the -A key to ssh agent forwarding. So, for operations inside the virtual machine, you will be able to use your ssh key from host machine.)

4. At this point you are in the project directory.

```bash
cd /vagrant
```

To compile the testnet use command:

```bash
make buildtest
```

To run the testnet please use the script:

```bash
./bin/testnet.sh
```

- start the local testnet:

```bash
./bin/testnet.sh start
```

- stop the testnet:

```bash
./bin/testnet.sh stop
```

Please, also consult the Makefile targets as reference how to make other different tasks.

You can see the API ports using the command:

```bash
netstat -an |grep 498
```

(After testnet was started you should see 9 different ports. You can use these ports for API calls of The Power nodes.)

Example API call:

```bash
curl http://pwr.local:49841/api/node/status | jq .
```

Please note, you may use the domain `pwr.local` in URL to reference the node from virtual machine or from host machine.
