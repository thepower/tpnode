# -*- mode: ruby -*-
# vi: set ft=ruby :

domains = [ 'pwr.local', 'dev.pwr.local' ]

Vagrant.configure("2") do |config|
  config.vm.box = "bento/ubuntu-16.04"
  config.vm.box_check_update = false
  config.vm.network "public_network", type: "dhcp", use_dhcp_assigned_default_route: true
  config.vm.hostname = "pwr"
  config.vm.synced_folder ".", "/vagrant"

  # parallels specific stuff
  config.vm.provider "parallels" do |prl|
    prl.update_guest_tools = true
    prl.memory = 1024
    prl.cpus = 2
  end

  # virtual box specific stuff
  config.vm.provider 'virtualbox' do |vb|
    vb.cpus = 2
    vb.memory = 1024
  end

  # hosts settings (host machine)
  config.vm.provision :hostmanager
  config.hostmanager.enabled            = true
  config.hostmanager.manage_host        = true
  config.hostmanager.ignore_private_ip  = false
  config.hostmanager.include_offline    = true
  config.hostmanager.aliases            = domains

  # disable ipv6 on eth0
  config.vm.provision "shell",
    run: "always",
    inline: "sysctl -w net.ipv6.conf.eth0.disable_ipv6=1"

  # delete default gw on eth0
  config.vm.provision "shell",
    run: "always",
    inline: "eval `route -n | awk '{ if ($8 ==\"eth0\" && $2 != \"0.0.0.0\") print \"route del default gw \" $2; }'`"

  config.vm.provision "shell", inline: <<-SHELL
    sudo apt update
    sudo apt install -y build-essential clang libsctp-dev libncurses5-dev mc curl libssl-dev automake autoconf jq tmux htop cmake

    # setup timezone
    echo 'Etc/UTC' > /etc/timezone
    dpkg-reconfigure --frontend noninteractive tzdata

    # install erlang
    wget https://raw.githubusercontent.com/kerl/kerl/master/kerl -O kerl -o /dev/null
    chmod +x kerl
    ./kerl update releases
    KERL_CONFIGURE_OPTIONS=--enable-sctp=lib ./kerl build 22.3 r22.3
    sudo ./kerl install r22.3 /opt/erl
    ./kerl cleanup all
    . /opt/erl/activate
    echo ". /opt/erl/activate" >> /home/vagrant/.bash_profile

    wget https://s3.amazonaws.com/rebar3/rebar3 -O rebar3 -o /dev/null
    sudo mv rebar3 /usr/local/bin
    sudo chmod +x /usr/local/bin/rebar3
    sudo chown root:root /usr/local/bin/rebar3
    if [ ! -e /vagrant/db ]
    then
      mkdir -p /home/vagrant/db
      ln -s /home/vagrant/db /vagrant/db
      chown vagrant:vagrant /home/vagrant/db /vagrant/db
    fi

    # add known hosts for git
    mkdir -p /home/vagrant/.ssh
    chmod 700 /home/vagrant/.ssh
    chown vagrant:vagrant /home/vagrant/.ssh
    echo "|1|oYXqrZWR2XaRQh9IjlyPiWN4l5o=|zUHUhYnkAyi/BrvofQe6E5Y8BG4= ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGBFLC1ss/I+yAk9IqvX8wm4zQjNtyaW9O/vdl8HCjZ0+ddQy7l5bay2FFNF5x0Hw6eU/1miwuEOrO9PwfBVBzA=" >> /home/vagrant/.ssh/known_hosts
    echo "|1|c5X9JpCbDIz7KgNDcP33b8VrmNk=|hDD/iMZb6luoi4OElIv6gTOeZG0= ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBGBFLC1ss/I+yAk9IqvX8wm4zQjNtyaW9O/vdl8HCjZ0+ddQy7l5bay2FFNF5x0Hw6eU/1miwuEOrO9PwfBVBzA=" >> /home/vagrant/.ssh/known_hosts
    echo "|1|2jVL0WWpxANQZId2nzaCGm9emnI=|Tq4s1sHMDkx01hjA7DfgfDObKtA= ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMZWRXPU4e2PUzbZ1VsbzK8ODZ8WZuoChXFr/hs1HlZnFpedcKFTPD/CibD3oqyH+m/yU9nm+v5cp8XTOs71YJ8=" >> /home/vagrant/.ssh/known_hosts
    echo "|1|4iROpK4oZ/vt2Db+8tbgm5lcR/I=|lp4/+Aca7cp6wzG+HQReD+VyFZ0= ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBMZWRXPU4e2PUzbZ1VsbzK8ODZ8WZuoChXFr/hs1HlZnFpedcKFTPD/CibD3oqyH+m/yU9nm+v5cp8XTOs71YJ8=" >> /home/vagrant/.ssh/known_hosts
  SHELL
end
