#!/bin/bash

# if set to anything other then 0, then some key things won't execute, this is for testing purposes only
DEBUG=0

[ ! "${LOGNAME}" = "root" ] && echo "You must be root, or sudo ${0}" && exit 1

# Set user name here of user that will be running the sandbox
CUSER="cuckoo"
ETH=enp0s31f6

function StartMessage()
{
	#clear

	cat<<eof
You will first be asked what user cuckoo will run under.
Accept the default or enter the name of the user it will run as.

*** The user account will be created if it does not exist
eof

	read -p "[${CUSER}] > "

	if [ ! "${REPLY}" = "" ]; then
		CUSER="${REPLY}"
	fi
}

function PrimaryPrereqs()
{
	#clear

	# Prereqs
	echo ">>> Installing Prereqs... with user ${CUSER} for configuration"
	apt-get update

	sleep 2; clear

	cat<<eof
First up, "iptables-persistent". Apt will likely ask you two install questions here.

One related to IPv4 and another to IPv6, accept the default for IPv4, IPv6 is optional.
eof

	read -N 1 -p "Hit any key when ready..."

	apt-get -y install iptables-persistent

	echo ">>> Ok, on to the less chatty stuff..."

	apt-get -y install git screen
	apt-get -y install python python-pip python-dev libffi-dev libssl-dev
	apt-get -y install python-virtualenv python-setuptools
	apt-get -y install libjpeg-dev zlib1g-dev swig
	apt-get -y install mongodb
	apt-get -y install postgresql libpq-dev

	sleep 2
}

function InstallVbox()
{
	#clear

	# Virtual Box
	echo ">>> Installing VirtualBox..."

	MIRROR="https://mirrors.kernel.org/ubuntu xenial main"
	VBSRC="deb http://download.virtualbox.org/virtualbox/debian xenial contrib"

	if [ ! -e /etc/apt/sources.list.d/virtualbox.list ]; then
		echo "${VBSRC}" | tee -a /etc/apt/sources.list.d/virtualbox.list
		wget -q https://www.virtualbox.org/download/oracle_vbox_2016.asc -O- | apt-key add -
		grep "${MIRROR}" /etc/apt/sources.list > /dev/null
	 	[ $? -gt 0 ] && echo "deb ${MIRROR}" >> /etc/apt/sources.list

		apt-get update
		apt-get -y install virtualbox-5.2
	fi

	sleep 2
}

function ConfigUser()
{
	#clear

	# Install user
	echo ">>> Setting up user..."
	if [ ! -e /home/${CUSER} ]; then
		adduser ${CUSER}

	fi

	if id -nG ${CUSER} | grep -qw vboxusers; then
		usermod -a -G vboxusers ${CUSER}
		# libvirtd used for KVM
		# usermod -a -G libvirtd ${CUSER}
	fi

	# Check for user's open file limits (in that if a statement exists, skip, otherwise, add)
	if ! grep -qw ${CUSER} /etc/security/limits.conf; then
		echo "Changing ${CUSER}'s open file limits"
		echo -e "${CUSER}\thard\tnofile\t500000" >> /etc/security/limits.conf
	fi

	sleep 2
}

function TcpDumpStuff()
{
	#clear

	# tcpdump and remove apparmor profile for it
	echo ">>> Installing, configuring tcpdump..."
	apt-get -y install tcpdump apparmor-utils
	aa-disable /usr/sbin/tcpdump

	# Check for existence of pcap group, create if needed
	if ! getent group pcap >/dev/null; then
		groupadd pcap
	fi

	# Add user to pcap group is not already
	if id -nG ${CUSER} | grep -qw pcap; then
		usermod -a -G pcap ${CUSER}
	fi

	chgrp pcap /usr/sbin/tcpdump

	#apt-get -y install libcap2-bin
	setcap cap_net_raw,cap_net_admin=eip /usr/sbin/tcpdump

	# verify pcap is needed
	# getcap /usr/sbin/tcpdump

	sleep 2
}

function InstallVolatility()
{
	#clear

	# Install volitility framework
	echo ">>> Installing volatility framework"
	if [ ! -e volatility ]; then
		git clone https://github.com/volatilityfoundation/volatility

		pushd volatility > /dev/null

		# python ./setup.py install Once finised use command
		python ./setup.py install

		popd > /dev/null
	fi
}

function PythonStuff()
{
	#clear

	# Python stuff, distorm3 cuckoo m2crypto's
	echo ">>> Configuring python support/cuckoo python reqs"
	pip install m2crypto==0.24.0

	# virtualenv venv
	# . venv/bin/activate

	pip install -U pip setuptools

	sleep 2
}

function InstallCuckoo()
{
	#clear

	echo ">>> Installing/configuring Cuckoo Sandbox"
	pip install -U cuckoo
	pip install distorm3

	[ ! -e /opt/cuckoo ] && mkdir /opt/cuckoo
	chown ${CUSER}:${CUSER} /opt/cuckoo

	# Set working dir
	[ DEBUG -eq 0 ] && cuckoo --cwd /opt/cuckoo

	sleep 2
}

function VBInitMsg()
{
	#clear

	cat<<eof
When you are ready, hit any key and Virtualbox will run to initialize.
You can immmediately close it when you are ready. It is best NOT to install
a Guest OS at this time, as it would end up as a Root guest and have permission
issues.
eof

	read -N 1 -p "Any key when ready..."

	# Initialize
	[ DEBUG -eq 0 ] && virtualbox

	sleep 2
}

function MkHostOnlyInterface()
{
	#clear

	ifconfig -a | grep -qw vboxnet0

	[ $? -eq 0 ] && echo "*** vboxnet0 appears to already exist, skipping..." && return 0

	echo "Creating host-only interface"
	vboxmanage hostonlyif create
	vboxmanage hostonlyif ipconfig vboxnet0 --ip 192.168.56.1

	ifconfig | grep -qw vboxnet0

	if [ $? -eq 0 ]; then
		echo "Good vboxnet0 interface was created"
	else
		echo "Bummer, vboxnet0 does not seem to have been created..."
	fi

	sleep 2
}

function IPTablesStuff()
{
	#clear

	[ DEBUG -gt 0 ] && return 0

	# IPTABLES Config
	echo "Final script step, setting up IPTABLES and making the changes permanant"
	iptables -t nat -A POSTROUTING -o ${ETH} -s 192.168.56.0/24 -j MASQUERADE
	iptables -P FORWARD DROP
	iptables -A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT
	iptables -A FORWARD -s 192.168.56.0/24 -j ACCEPT
	iptables -A FORWARD -s 192.168.56.0/24 -d 192.168.56.0/24 -j ACCEPT
	iptables-save > /etc/iptables/rules.v4

	sleep 2
}

function EnableForwarding()
{
	#clear

	echo 1 | tee -a /proc/sys/net/ipv4/ip_forward
	sysctl -w net.ipv4.ip_forward=1

	sleep 2
}

function EndMessage()
{
	#clear
	cat<<eof
Install a Guest OS, be sure to set it's Network Interface to "Host-Only".
Do this as the user who will run Cuckoo.

Go into your chosen VM guest's properties in the Virtual Box main app.
Select the VM's properties, select the Networking tab and change the
"Attached To" setting to "Host Only Adapter" and then select vboxnet0
in the "Name" dropdown.
eof
}

#
# Main Loop
#

StartMessage

PrimaryPrereqs
InstallVbox
ConfigUser
TcpDumpStuff
InstallVolatility
PythonStuff
VBInitMsg
MkHostOnlyInterface
IPTablesStuff
EnableForwarding

EndMessage
