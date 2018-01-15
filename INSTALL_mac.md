# Mac OS

## Prerequirement

- You must use SMP machine.
- Before doing anything below ensure you have the comand line tools are installed. This can be done executing

```
xcode-select --install
```


## Disable mac os "ass-security" (System Integrity Protection) in osx

- check status with ```csrutil status``` if it disabled skip next steps
- Boot to Recovery OS by powering your machine off. After that power on and anstantly hold down the Command and R keys
- Launch Terminal from the Utilities menu. 
- Enter the following commands:

```
csrutil disable
reboot
```

## Install homebrew

```
/usr/bin/ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
brew install openssl kerl wget
```

## Install kext for SCTP

```

wget https://github.com/sctplab/SCTP_NKE_ElCapitan/releases/download/v01/SCTP_NKE_ElCapitan_Install_01.dmg
open SCTP_NKE_ElCapitan_Install_01.dmg

sudo cp -R /Volumes/SCTP_NKE_ElCapitan_01/SCTPSupport.kext /Library/Extensions
sudo cp -R /Volumes/SCTP_NKE_ElCapitan_01/SCTP.kext /Library/Extensions
sudo cp /Volumes/SCTP_NKE_ElCapitan_01/socket.h /usr/include/sys/
sudo cp /Volumes/SCTP_NKE_ElCapitan_01/sctp.h /usr/include/netinet/
sudo cp /Volumes/SCTP_NKE_ElCapitan_01/sctp_uio.h /usr/include/netinet/
sudo cp /Volumes/SCTP_NKE_ElCapitan_01/libsctp.dylib /usr/lib/

sudo kextload /Library/Extensions/SCTP.kext
```

## Build Erlang with SCTP support


```
kerl update releases

export KERL_CONFIGURE_OPTIONS=" --enable-vm-probes --with-dynamic-trace=dtrace \
--with-ssl=/usr/local/Cellar/openssl/1.0.2n --enable-hipe --enable-kernel-poll \
--without-odbc --enable-threads --enable-sctp=lib --enable-smp-support"

kerl build 20.2 r20_2
```

After build complete you should see following message:

```
Erlang/OTP 20.2 (r20_2) has been successfully built
```

Now you can install erlang

```
sudo mkdir /usr/local/erlang
sudo chmod 777 /usr/local/erlang
kerl install r20_2 /usr/local/erlang
```

After successfull install you will see folowing message

```
Installing Erlang/OTP 20.2 (r20_2) in /usr/local/erlang...
You can activate this installation running the following command:
. /usr/local/erlang/activate
Later on, you can leave the installation typing:
kerl_deactivate
```

Now you can use this erlang by activating with following command:

```
. /usr/local/erlang/activate
```

