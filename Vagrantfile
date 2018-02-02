# -*- mode: ruby -*-
# vi: set ft=ruby :

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-16.04"
  config.vm.box_check_update = false

  config.vm.provision "shell", inline: <<-SHELL
    wget https://packages.erlang-solutions.com/erlang-solutions_1.0_all.deb -O erlang-solutions_1.0_all.deb -o /dev/null
    sudo dpkg -i erlang-solutions_1.0_all.deb
    rm -f erlang-solutions_1.0_all.deb
    sudo apt-get update
    sudo apt-get install -y erlang-nox erlang-dev build-essential clang mc
    wget https://github.com/erlang/rebar3/releases/download/3.5.0/rebar3 -O rebar3 -o /dev/null
    sudo mv rebar3 /usr/local/bin
    sudo chmod +x /usr/local/bin/rebar3
    sudo chown root:root /usr/local/bin/rebar3
  SHELL
end
