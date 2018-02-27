# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-16.04"
  config.vm.box_check_update = false
  config.vm.network "public_network", type: "dhcp", use_dhcp_assigned_default_route: true
  config.vm.hostname = "pwr"

  # disable ipv6 on eth0
  config.vm.provision "shell",
    run: "always",
    inline: "sysctl -w net.ipv6.conf.eth0.disable_ipv6=1"

  # delete default gw on eth0
  config.vm.provision "shell",
    run: "always",
    inline: "eval `route -n | awk '{ if ($8 ==\"eth0\" && $2 != \"0.0.0.0\") print \"route del default gw \" $2; }'`"

  config.vm.provision "shell", inline: <<-SHELL
    sudo apt-get update
    sudo apt-get install -y build-essential clang libsctp-dev libncurses5-dev mc

    # install erlang
    wget https://raw.githubusercontent.com/kerl/kerl/master/kerl -O kerl -o /dev/null
    chmod +x kerl
    ./kerl update releases
    KERL_CONFIGURE_OPTIONS=--enable-sctp=lib ./kerl build 20.2 r20.2
    sudo ./kerl install r20.2 /opt/erl
    ./kerl cleanup all
    . /opt/erl/activate
    echo ". /opt/erl/activate" >> /home/vagrant/.bashrc

    wget https://github.com/erlang/rebar3/releases/download/3.5.0/rebar3 -O rebar3 -o /dev/null
    sudo mv rebar3 /usr/local/bin
    sudo chmod +x /usr/local/bin/rebar3
    sudo chown root:root /usr/local/bin/rebar3
    if [ ! -e /vagrant/db ]
    then
      mkdir -p /home/vagrant/db
      ln -s /home/vagrant/db /vagrant/db
      chown vagrant:vagrant /home/vagrant/db /vagrant/db
    fi
  SHELL
end
