#!/bin/bash

# Author: neo3587
# Source: https://github.com/neo3587/dupmn

# TODO:
# - even more extended info on list ?
# - separated service generator script file for main node ?
# - check ipinstall ip is same than other dupes and main MN, if true => listen = 0 and advertise
# - dupmn ipadd <ip> <netmask> <inc> # may require hard reset
# - dupmn ipdel <ip> # not main one
# options (all of them requires a lot of debug for ipadd and ipdel):
#	1. /etc/network/interfaces : tricky and dangerous but most effective, requires hard restart (combinate with 2. to not require hard restart ?)
#   2. /etc/init.d/dupmn_ip_manager => ip address add IP/netmask_cidr(NET_MASK) dev INTERFACE : viable, no reset needed, add [Service] ExecStartPre=/bin/sleep 10
#		#For permanent activation, either a special initscript value per interface will enable privacy or an entry in the /etc/sysctl.conf file like
#		net.ipv6.conf.eth0.use_tempaddr=2
#		#Note: interface must already exists with proper name when sysctl.conf is applied. If this is not the case (e.g. after reboot) one has to configure privacy for all interfaces by default:
#		net.ipv6.conf.all.use_tempaddr=2
#		net.ipv6.conf.default.use_tempaddr=2
#		#Changed/added values in /etc/sysctl.conf can be activated during runtime, but at least an interface down/up or a reboot is recommended.
#		sysctl -p
#
# ip bind options:
#   1. bind main & dupe
#   2. bind dupe on unused port => need to check if actually can be activated


readonly RED='\e[1;31m'
readonly GREEN='\e[1;32m'
readonly YELLOW='\e[1;33m'
readonly BLUE='\e[1;34m'
readonly MAGENTA='\e[1;35m'
readonly CYAN='\e[1;36m'
readonly UNDERLINE='\e[1;4m'
readonly NC='\e[0m'


coin_name=""
coin_daemon=""
coin_cli=""
coin_folder=""
coin_config=""
rpc_port=""
dup_count=""
exec_coin_cli=""
exec_coin_daemon=""
ip=""


function get_conf() {
	# <$1 = conf_file>
	local str_map="";
	for line in `sed '/^$/d' $1`; do
		str_map+="[${line%=*}]=${line#*=} "
	done
	echo -e "( $str_map )"
}
function port_check() {
	# <$1 = port_number>
	[[ ! $(lsof -Pi :$1 -sTCP:LISTEN -t) ]] && echo "1"
}
function find_port() {
	# <$1 = initial_check>

	function port_check_loop() {
		for (( i=$1; i<=$2; i++ )); do
			if [[ ! "${3}[@]" =~ "${i}" && $(port_check $i) ]]; then
				echo -e "$i"
				return
			fi
		done
	}

	local dup_ports=""
	for (( i=1; i<=$dup_count; i++ )); do
		dup_ports="$dup_ports $(conf_get_value $coin_folder$i/$coin_config rpcport) "
	done
	local port=$(port_check_loop $1 49151 "( $dup_ports )")
	[[ -n "$port" ]] && echo $port || echo $(port_check_loop 1024 $1 "( $dup_ports )")
}
function is_number() {
	# <$1 = number>
	[[ "$1" =~ ^[0-9]+$ ]] && echo "1"
}
function configure_systemd() {
	# <$1 = instance_number>

	echo -e "[Unit]\
	\nDescription=$coin_name-$1 service\
	\nAfter=network.target\
	\n\
	\n[Service]\
	\nUser=root\
	\nGroup=root\
	\nType=forking\
	\nExecStart=$exec_coin_daemon -daemon -conf=$coin_folder$1/$coin_config -datadir=$coin_folder$1\
	\nExecStop=$exec_coin_cli -conf=$coin_folder$1/$coin_config -datadir=$coin_folder$1 stop\
	\nRestart=always\
	\nPrivateTmp=true\
	\nTimeoutStopSec=60s\
	\nTimeoutStartSec=10s\
	\nStartLimitInterval=120s\
	\nStartLimitBurst=5\
	\n\
	\n[Install]\
	\nWantedBy=multi-user.target" > /etc/systemd/system/$coin_name-$1.service
	chmod +x /etc/systemd/system/$coin_name-$1.service

	systemctl daemon-reload
	sleep 3
	systemctl start $coin_name-$1.service
	systemctl enable $coin_name-$1.service > /dev/null 2>&1

	if [[ -z "$(ps axo cmd:100 | egrep $coin_name-$1)" ]]; then
		echo -e "\n${RED}IMPORTANT!!!${NC} \
			\nSeems like there might be a problem with the systemctl configuration, please investigate.\
			\nYou should start by running the following commands:\
			\n${GREEN}systemctl start  $coin_name-$2.service${NC}\
			\n${GREEN}systemctl status $coin_name-$2.service${NC}\
			\n${GREEN}less /var/log/syslog${NC}\
			\nThe most common causes of this might be that either you made something to a file that dupmn modifies or creates, or that you don't have enough free resources (usually memory).
			\nThere's also the chance that this could be a false positive error (so actually everything is ok), anyway please use the commands above to investigate."
	fi
}
function wallet_loaded() {
	exec 2> /dev/null
	[[ $(is_number $($coin_cli getblockcount)) ]] && echo "1"
	exec 2> /dev/tty
}
function install_proc() {
	# <$1 = profile_name> | <$2 = instance_number> | [$3 = copy]

	if [ ! -d "$coin_folder" ]; then
		echo -e "$coin_folder folder can't be found, $coin_name is not installed in the system or the given profile has a wrong parameter"
		exit
	elif [ ! "$(command -v lsof)" ]; then
		echo -e "lsof is not installed in the system, use ${CYAN}apt-get install lsof${NC} and retry the installation"
		exit
	fi

	new_folder="$coin_folder$2"

	if [[ "$3" == "copy" ]]; then
		if [[ $(wallet_loaded) ]]; then
			echo -e "Main masternode must be stopped to copy the chain on install, use ${GREEN}$coin_cli stop${NC} to stop the main node\nNOTE: Some main nodes may need to stop a systemctl service instead"
			exit
		fi
		echo "Copying main node chain... (may take a while)"
		rm -rf $new_folder
		rsync -adm --info=progress2 $coin_folder/ $new_folder/
		rm -rf $new_folder/$coin_config
		rm -rf $new_folder/wallet.dat
		$exec_coin_daemon -daemon >  /dev/null 2>&1
		echo "Temporary reactivating the wallet to get a new private key..."
		while [[ ! $(wallet_loaded) ]]; do
			sleep 1
		done
	fi

	if [[ ! $(wallet_loaded) ]]; then
		echo -e "Main masternode must be running to create a duplicate masternode, use ${GREEN}$coin_daemon -daemon${NC} to start the main masternode"
		exit
	fi

	new_key=$($coin_cli masternode genkey)
	new_rpc=$(conf_get_value .dupmn/$1 "RPC_PORT")
	new_rpc=$([[ -n $new_rpc ]] && echo $new_rpc || conf_get_value $coin_folder/$coin_config "rpcport")
	new_rpc=$(find_port $(($([[ -n $new_rpc ]] && echo $new_rpc || echo "1023")+1)))

	[[ "$3" == "copy" ]] && $coin_cli stop > /dev/null 2>&1

	mkdir $new_folder > /dev/null 2>&1
	cp $coin_folder/$coin_config $new_folder

	local new_user=$(conf_get_value $coin_folder/$coin_config "rpcuser")
	local new_pass=$(conf_get_value $coin_folder/$coin_config "rpcpassword")
	new_user=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $([[ ${#new_user} -gt 3 ]] && echo ${#new_user} || echo 10) | head -n 1)
	new_pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9' | fold -w $([[ ${#new_pass} -gt 6 ]] && echo ${#new_pass} || echo 22) | head -n 1)

	$(conf_set_value $new_folder/$coin_config "rpcuser"           $new_user 1)
	$(conf_set_value $new_folder/$coin_config "rpcpassword"       $new_pass 1)
	$(conf_set_value $new_folder/$coin_config "rpcport"           $new_rpc  1)
	$(conf_set_value $new_folder/$coin_config "listen"            "0"       1)
	$(conf_set_value $new_folder/$coin_config "masternodeprivkey" $new_key  1)

	$(make_chmod_file /usr/bin/$coin_cli-0      "#!/bin/bash\n$exec_coin_cli \$@")
    $(make_chmod_file /usr/bin/$coin_daemon-0   "#!/bin/bash\n$exec_coin_daemon \$@")
	$(make_chmod_file /usr/bin/$coin_cli-$2     "#!/bin/bash\n$exec_coin_cli -datadir=$new_folder \$@")
	$(make_chmod_file /usr/bin/$coin_daemon-$2  "#!/bin/bash\n$exec_coin_daemon -datadir=$new_folder \$@")
	$(make_chmod_file /usr/bin/$coin_cli-all    "#!/bin/bash\nfor (( i=0; i<=$2; i++ )) do\n echo -e MN\$i:\n $coin_cli-\$i \$@\ndone")
	$(make_chmod_file /usr/bin/$coin_daemon-all "#!/bin/bash\nfor (( i=0; i<=$2; i++ )) do\n echo -e MN\$i:\n $coin_daemon-\$i \$@\ndone")

	$(conf_set_value .dupmn/dupmn.conf $1 $2 1)
}
function conf_set_value() {
	# <$1 = conf_file> | <$2 = key> | <$3 = value> | [$4 = force_create]
	[[ $(grep -ws "^$2" "$1" | cut -d "=" -f1) == "$2" ]] && sed -i "/^$2=/s/=.*/=$3/" "$1" || ([[ "$4" == "1" ]] && echo -e "$2=$3" >> $1)
}
function conf_get_value() {
        # <$1 = conf_file> | <$2 = key>| [$3 = limit]
        [[ "$3" == "0" ]] && grep -ws "^$2" "$1" | cut -d "=" -f2 || grep -ws "^$2" "$1" | cut -d "=" -f2 | head $([[ -z "$3" ]] && echo "-1" || echo "-$3")
}
function make_chmod_file() {
	# <$1 = file> | <$2 = content>
	echo -e "$2" > $1
	chmod +x $1
}
function get_ips() {
	# <$1 = 4 or 6>
	if [[ "$1" = "4" ]]; then
		echo -e $(ip addr show | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*' | grep -v '127.0.0.1')
	elif [[ "$1" = "6" ]]; then
		echo -e $(ip addr show | awk '/inet6/{print $2}' | grep -v '::1/128' | cut -d / -f1)
	fi
}
function netmask_cidr() {
	# <$1 = netmask>
	if [[ $(echo $1 | grep -w -E -o '^(254|252|248|240|224|192|128)\.0\.0\.0|255\.(254|252|248|240|224|192|128|0)\.0\.0|255\.255\.(254|252|248|240|224|192|128|0)\.0|255\.255\.255\.(255|254|252|248|240|224|192|128|0)') ]]; then
        local nbits=0
        for oct in $(echo $1 | tr "." " "); do
            while [[ $oct -gt 0 ]]; do
                oct=$(($oct << 1 & 255))
                nbits=$(($nbits+1))
            done
        done
        echo "$nbits"
    fi
}


function cmd_profadd() {
	# <$1 = profile_file> | <$2 = profile_name>

	local -A prof=$(get_conf $1)
	local CMD_ARRAY=(COIN_NAME COIN_DAEMON COIN_CLI COIN_FOLDER COIN_CONFIG)

	for var in "${CMD_ARRAY[@]}"; do
		if [[ ! "${!prof[@]}" =~ "$var" ]]; then
			echo -e "${MAGENTA}$var${NC} doesn't exists in the supplied profile file"
			exit
		elif [[ -z "${prof[$var]}" ]]; then
			echo -e "${MAGENTA}$var${NC} doesn't contain a value in the supplied profile file"
			exit
		fi
	done

	if [[ "$2" = "dupmn.conf" ]]; then 
		echo -e "From the infinite amount of possible names for the profile and you had to choose the only one that you can't use... for god sake..."
		exit
	fi

	[[ ! -d ".dupmn" ]] && mkdir ".dupmn"
	[[ ! -f ".dupmn/dupmn.conf" ]] && touch ".dupmn/dupmn.conf"
	$(conf_set_value .dupmn/dupmn.conf $2 0 1)

	cp "$1" ".dupmn/$2"

	local fix_path=${prof[COIN_PATH]}
	local fix_folder=${prof[COIN_FOLDER]}

	if [[ ${fix_path:${#fix_path}-1:1} != "/" ]]; then
		sed -i "/^COIN_PATH=/s/=.*/=\"${fix_path//"/"/"\/"}\/\"/" .dupmn/$2
	fi
	if [[ ${fix_folder:${#fix_folder}-1:1} = "/" ]]; then
		fix_folder=${fix_folder::-1}
		sed -i "/^COIN_FOLDER=/s/=.*/=\"${fix_folder//"/"/"\/"}\"/" .dupmn/$2
	fi

	echo -e "${BLUE}$2${NC} profile successfully added, use ${GREEN}dupmn install $2${NC} to create a new instance of the masternode"
}
function cmd_profdel() {
	# <$1 = profile_name>

	if [ $dup_count -gt 0 ]; then
		cmd_uninstall $1 all
	fi
	sed -i "/$1\=/d" ".dupmn/dupmn.conf"

	rm -rf /usr/bin/$coin_daemon-0
	rm -rf /usr/bin/$coin_daemon-all
	rm -rf /usr/bin/$coin_cli-0
	rm -rf /usr/bin/$coin_cli-all
	rm -rf .dupmn/$1
}
function cmd_install() {
	# <$1 = profile_name> | <$2 = instance_number> | [$3 = copy]

	install_proc $1 $2 $3
	configure_systemd $2

	echo -e "===================================================================================================\
			\n${BLUE}$coin_name${NC} duplicated masternode ${CYAN}number $2${NC} should be now up and trying to sync with the blockchain.\
			\nThe duplicated masternode uses the same IP and PORT than the original one.\
			\nRPC port is ${MAGENTA}$new_rpc${NC}, this one is used to send commands to the wallet, DON'T put it in 'masternode.conf' (other programs might want to use this port which causes a conflict, but you can change it with ${MAGENTA}dupmn rpcchange $1 $2 PORT_NUMBER${NC}).\
			\nStart:              ${RED}systemctl start   $coin_name-$2.service${NC}\
			\nStop:               ${RED}systemctl stop    $coin_name-$2.service${NC}\
			\nStart on reboot:    ${RED}systemctl enable  $coin_name-$2.service${NC}\
			\nNo start on reboot: ${RED}systemctl disable $coin_name-$2.service${NC}\
			\n(Currently configured to start on reboot)\
			\nDUPLICATED MASTERNODE PRIVATEKEY is: ${GREEN}$new_key${NC}\
			\nTo check the masternode status just use: ${GREEN}$coin_cli-$2 masternode status${NC} (Wait until the new masternode is synced with the blockchain before trying to start it).\
			\nNOTE 1: ${GREEN}$coin_cli-0${NC} and ${GREEN}$coin_daemon-0${NC} are just a reference to the 'main masternode', not a created one with dupmn.\
			\nNOTE 2: You can use ${GREEN}$coin_cli-all [parameters]${NC} and ${GREEN}$coin_daemon-all [parameters]${NC} to apply the parameters on all masternodes. Example: ${GREEN}$coin_cli-all masternode status${NC}\
			\n==================================================================================================="
	[[ "$3" == "copy" ]] && echo -e "\nYou can now start again the main node\n"
}
function cmd_reinstall() {
	# <$1 = profile_name> | <$2 = instance_number> | <$3 = use_ipinstall> | [$4 = copy]

	if [[ "$4" != "copy" && ! $(wallet_loaded) ]]; then
		echo -e "Main masternode must be running to reinstall a duplicate masternode, use ${GREEN}$coin_daemon -daemon${NC} to start the main masternode"
		exit
	elif [[ "$4" == "copy" && $(wallet_loaded) ]]; then
		echo -e "Main masternode must be stopped to copy the chain on reinstall, use ${GREEN}$coin_cli stop${NC} to stop the main node\nNOTE: Some main nodes may need to stop a systemctl service instead"
		exit
	fi

	systemctl stop $coin_name-$2.service
	rm -rf $coin_folder$2

	if [[ "$3" == "0" ]]; then
		cmd_install $1 $2 $4
	else
		cmd_ipinstall $1 $2 $4
	fi

	$(make_chmod_file /usr/bin/$coin_cli-all    "#!/bin/bash\nfor (( i=0; i<=$dup_count; i++ )) do\n echo -e MN\$i:\n $coin_cli-\$i \$@\ndone")
	$(make_chmod_file /usr/bin/$coin_daemon-all "#!/bin/bash\nfor (( i=0; i<=$dup_count; i++ )) do\n echo -e MN\$i:\n $coin_daemon-\$i \$@\ndone")

	$(conf_set_value .dupmn/dupmn.conf $1 $dup_count)
}
function cmd_uninstall() {
	# <$1 = profile_name> | <$2 = instance_number/all>

	if [ $dup_count = 0 ]; then
		echo -e "There aren't duplicated ${BLUE}$1${NC} masternodes to remove"
		exit
	fi

	if [ "$2" = "all" ]; then
		for (( i=$dup_count; i>=1; i-- )); do
			echo -e "Uninstalling ${BLUE}$1${NC} instance ${CYAN}number $i${NC}"
			rm -rf /usr/bin/$coin_cli-$i
			rm -rf /usr/bin/$coin_daemon-$i
			systemctl stop $coin_name-$i.service > /dev/null
			systemctl disable $coin_name-$i.service > /dev/null 2>&1
			rm -rf /etc/systemd/system/$coin_name-$i.service
			rm -rf $coin_folder$i
		done
		$(conf_set_value .dupmn/dupmn.conf $1 0 1)
		$(make_chmod_file /usr/bin/$coin_cli-all    "#!/bin/bash\nfor (( i=0; i<=0; i++ )) do\n echo -e MN\$i:\n $coin_cli-\$i \$@\ndone")
		$(make_chmod_file /usr/bin/$coin_daemon-all "#!/bin/bash\nfor (( i=0; i<=0; i++ )) do\n echo -e MN\$i:\n $coin_daemon-\$i \$@\ndone")
		systemctl daemon-reload
	else
		echo -e "Uninstalling ${BLUE}$1${NC} instance ${CYAN}number $2${NC}"
		rm -rf /usr/bin/$coin_cli-$dup_count
		rm -rf /usr/bin/$coin_daemon-$dup_count
		systemctl stop $coin_name-$2.service
		$(conf_set_value .dupmn/dupmn.conf $1 $(($dup_count-1)) 1)
		$(make_chmod_file /usr/bin/$coin_cli-all "#!/bin/bash\nfor (( i=0; i<=$(($dup_count-1)); i++ )) do\n echo -e MN\$i:\n $coin_cli-\$i \$@\ndone")
		$(make_chmod_file /usr/bin/$coin_daemon-all "#!/bin/bash\nfor (( i=0; i<=$(($dup_count-1)); i++ )) do\n echo -e MN\$i:\n $coin_daemon-\$i \$@\ndone")
		rm -rf $coin_folder$2

		for (( i=$2; i<=$dup_count; i++ )); do
			systemctl stop $coin_name-$i.service
		done
		for (( i=$2+1; i<=$dup_count; i++ )); do
			echo -e "setting ${CYAN}instance $i${NC} as ${CYAN}instance $(($i-1))${NC}..."
			mv $coin_folder$i $coin_folder$(($i-1))
			systemctl start $coin_name-$(($i-1)).service
		done

		systemctl disable $coin_name-$dup_count.service > /dev/null 2>&1
		rm -rf /etc/systemd/system/$coin_name-$dup_count.service
		systemctl daemon-reload
	fi
}
function cmd_ipinstall() {
	# <$1 = profile_name> | <$2 = instance_number> | [$3 = copy]

	echo -e "!!! This command stills in beta state !!!"

	# IP repeated check:
	# local netstat_list=$(netstat -Wlantp | grep LISTEN | grep $coin_daemon)
	# for each IP => echo netstat_list | grep $ip_from_list

	install_proc $1 $2 $3

	local mn_addr_port=$(echo $(conf_get_value $new_folder/$coin_config "masternodeaddr") | rev | cut -d ":" -f1 | rev) 
	mn_addr_port=$([[ "$mn_addr_port" =~ ^[0-9]+$ ]] && echo ":$mn_addr_port" || echo "")

	$(conf_set_value $new_folder/$coin_config "listen"         "1"              1)
	$(conf_set_value $new_folder/$coin_config "externalip"     $ip              0)
	$(conf_set_value $new_folder/$coin_config "masternodeaddr" $ip$mn_addr_port 0)
	$(conf_set_value $new_folder/$coin_config "bind"           $ip              1)

	if [[ -z $(conf_get_value $coin_folder/$coin_config "bind") ]]; then
		echo "Applying a tiny modification into the main masternode conf file, this only will be applied this time..."
		local main_ip=$(conf_get_value $new_folder/$coin_config "masternodeaddr")
		$(conf_set_value $coin_folder/$coin_config "bind" $([[ -z "$main_ip" ]] && echo $(conf_get_value $coin_folder/$coin_config "externalip") || echo "$main_ip") 1)
		$exec_coin_cli stop > /dev/null 2>&1
		sleep 5
		$exec_coin_daemon -daemon > /dev/null 2>&1
	fi

	configure_systemd $2

	echo -e "===================================================================================================\
			\n${BLUE}$coin_name${NC} duplicated masternode ${CYAN}number $2${NC} should be now up and trying to sync with the blockchain.\
			\nThe duplicated masternode uses the IP ${YELLOW}$ip${NC} and the same PORT than the original one.\
			\nRPC port is ${MAGENTA}$new_rpc${NC}, this one is used to send commands to the wallet, DON'T put it in 'masternode.conf' (other programs might want to use this port which causes a conflict, but you can change it with ${MAGENTA}dupmn rpcchange $1 $2 PORT_NUMBER${NC}).\
			\nStart:              ${RED}systemctl start   $coin_name-$2.service${NC}\
			\nStop:               ${RED}systemctl stop    $coin_name-$2.service${NC}\
			\nStart on reboot:    ${RED}systemctl enable  $coin_name-$2.service${NC}\
			\nNo start on reboot: ${RED}systemctl disable $coin_name-$2.service${NC}\
			\n(Currently configured to start on reboot)\
			\nDUPLICATED MASTERNODE PRIVATEKEY is: ${GREEN}$new_key${NC}\
			\nTo check the masternode status just use: ${GREEN}$coin_cli-$2 masternode status${NC} (Wait until the new masternode is synced with the blockchain before trying to start it).\
			\nNOTE 1: ${GREEN}$coin_cli-0${NC} and ${GREEN}$coin_daemon-0${NC} are just a reference to the 'main masternode', not a created one with dupmn.\
			\nNOTE 2: You can use ${GREEN}$coin_cli-all [parameters]${NC} and ${GREEN}$coin_daemon-all [parameters]${NC} to apply the parameters on all masternodes. Example: ${GREEN}$coin_cli-all masternode status${NC}\
			\n==================================================================================================="
	[[ "$3" == "copy" ]] && echo -e "\nYou can now start again the main node\n"
}
function cmd_iplist() {
	echo -e "${GREEN}IPv4:${NC}"
	for ip in $(get_ips 4); do
		echo -e " $ip"
	done
	echo -e "${GREEN}IPv6:${NC}"
	for ip in $(get_ips 6); do
		echo -e " $ip"
	done
}
function cmd_rpcchange() {
	# <$1 = profile_name> | <$2 = instance_number> | [$3 = port_number]

	local new_port=$(($(conf_get_value $coin_folder$2/$coin_config "rpcport")))

	if [[ -z "$3" ]]; then
		echo -e "No port provided, the port will be changed for any other free port..."
		new_port=$(find_port $new_port)
	elif [[ ! $(is_number $3) ]]; then
		echo -e "${YELLOW}dupmn rpcchange <prof_name> <number> [port]${NC}, [port] must be a number"
		exit
	elif [[ $(($3)) -lt 1024 || $(($3)) -gt 49151 ]]; then
		echo -e "${MAGENTA}$3${NC} is not a valid or a reserved port (must be between ${MAGENTA}1024${NC} and ${MAGENTA}49151${NC})"
		exit
	else
		new_port=$(($3))
		if [[ ! $(port_check $new_port) ]]; then
			echo -e "Port ${MAGENTA}$new_port${NC} seems to be in use by another process"
			exit
		fi
	fi

	$(conf_set_value $coin_folder$2/$coin_config "rpcport" $new_port 1)
	systemctl stop $coin_name-$2.service > /dev/null
	systemctl start $coin_name-$2.service

	echo -e "${BLUE}$1${NC} instance ${CYAN}number $2${NC} is now listening the rpc port ${MAGENTA}$new_port${NC}"
}
function cmd_systemctlall() {
	# <$1 = profile_name> | <$2 = command>

	trap '' 2
	for (( i=1; i<=$dup_count; i++ )); do
		echo -e "${CYAN}systemctl $2 $coin_name-$i.service${NC}"
		systemctl $2 $coin_name-$i.service
	done
	trap 2
}
function cmd_list() {
	# [$1 = profile_name]

	if [[ -z "$1" ]]; then
		local -A conf=$(get_conf .dupmn/dupmn.conf)
		if [ ${#conf[@]} -eq 0 ]; then
			echo -e "(no profiles added)"
		else
			for var in "${!conf[@]}"; do
				echo -e "$var : ${conf[$var]}"
			done
		fi
	else
		function print_dup_info() {
			local dup_ip=$(conf_get_value $coin_folder$1/$coin_config "masternodeaddr")
			echo -e  "  ip      : ${YELLOW}$([[ -z "$dup_ip" ]] && echo $(conf_get_value $coin_folder$1/$coin_config "externalip") || echo "$dup_ip")${NC}\
					\n  rpcport : ${MAGENTA}$(conf_get_value $coin_folder$1/$coin_config rpcport)${NC}\
					\n  privkey : ${GREEN}$(conf_get_value $coin_folder$1/$coin_config masternodeprivkey)${NC}"
		}
		echo -e "${BLUE}$1${NC}: ${CYAN}$dup_count${NC} created nodes with dupmn"
		echo -e "Main Node:\n$(print_dup_info)"
		for (( i=1; i<=$dup_count; i++ )); do
			echo -e "MN$i:\n$(print_dup_info $i)"
		done
	fi
}
function cmd_swapfile() {
	# <$1 = size_in_mbytes>

	if [[ ! $(is_number $1) ]]; then
		echo -e "${YELLOW}<size_in_mbytes>${NC} must be a number"
		exit
	fi

	local avail_mb=$(df / --output=avail -m | grep [0-9])
	local total_mb=$(df / --output=size -m | grep [0-9])

	if [[ $(($1)) -ge $(($avail_mb)) ]]; then
		echo -e "There's only $(($avail_mb)) MB available in the hard disk"
		exit
	fi

	[[ -f /mnt/dupmn_swapfile ]] && swapoff /mnt/dupmn_swapfile > /dev/null 2>&1

	if [[ $(($1)) = 0 ]]; then
		rm -rf /mnt/dupmn_swapfile
		echo -e "Swapfile deleted"
	else
		echo -e "Generating swapfile, this may take some time depending on the size..."
		dd if=/dev/zero of=/mnt/dupmn_swapfile bs=1024 count=$(($1 * 1024)) > /dev/null 2>&1
		chmod 600 /mnt/dupmn_swapfile > /dev/null 2>&1
		mkswap /mnt/dupmn_swapfile > /dev/null 2>&1
		swapon /mnt/dupmn_swapfile > /dev/null 2>&1
		/mnt/dupmn_swapfile swap swap defaults 0 0 > /dev/null 2>&1
		echo -e "Swapfile new size = ${GREEN}$(($1)) MB${NC}"
	fi

	echo -e "Use ${YELLOW}swapon -s${NC} to see the changes of your swapfile and ${YELLOW}free -m${NC} to see the total available memory"
}
function cmd_help() {
	echo -e "Options:\
			\n  - ${YELLOW}dupmn profadd <prof_file> <prof_name>              ${NC}Adds a profile with the given name that will be used to create duplicates of the masternode\
			\n  - ${YELLOW}dupmn profdel <prof_name>                          ${NC}Deletes the given profile name, this will uninstall too any duplicated instance that uses this profile\
			\n  - ${YELLOW}dupmn install <prof_name> [copy]                   ${NC}Install a new instance based on the parameters of the given profile name, you can put ${YELLOW}copy${NC} as an extra parameter to copy the chain from the main node\
			\n  - ${YELLOW}dupmn reinstall <prof_name> <number> [copy]        ${NC}Reinstalls the specified instance, this is just in case if the instance is giving problems, you can put ${YELLOW}copy${NC} as an extra parameter to copy the chain from the main node\
			\n  - ${YELLOW}dupmn uninstall <prof_name> <number>               ${NC}Uninstall the specified instance of the given profile name, you can put ${YELLOW}all${NC} instead of a number to uninstall all the duplicated instances\
			\n  - ${YELLOW}dupmn iplist                                       ${NC}Shows all your configurated IPv4 and IPv6\
			\n  - ${YELLOW}dupmn rpcchange <prof_name> <number> [port]        ${NC}Changes the RPC port used from the given number instance with the new one (or finds a new one by itself if no port is given)\
			\n  - ${YELLOW}dupmn systemctlall <prof_name> <command>           ${NC}Applies the systemctl command to all the duplicated instances of the given profile name (but not the main instance)\
			\n  - ${YELLOW}dupmn list [prof_name]                             ${NC}Shows the amount of duplicated instances of every masternode, if a profile name is provided, it lists an extended info of the profile instances\
			\n  - ${YELLOW}dupmn swapfile <size_in_mbytes>                    ${NC}Creates, changes or deletes (if parameter is 0) a swapfile of the given size in MB to increase the virtual memory\
			\n  - ${YELLOW}dupmn about                                        ${NC}Shows some info about the script\
			\n${RED}BETA Options:${NC}\
			\n  - ${YELLOW}dupmn ipinstall <prof_name> <ip> [copy]            ${NC}Install a new instance based on the parameters of the given profile name that will use the given IP, you can put ${YELLOW}copy${NC} as an extra parameter to copy the chain from the main node\
			\n  - ${YELLOW}dupmn ipreinstall <prof_name> <number> <ip> [copy] ${NC}Reinstalls the specified instance with the given IP, this is just in case if the instance is giving problems, you can put ${YELLOW}copy${NC} as an extra parameter to copy the chain from the main node\
			\n**NOTE**: ${YELLOW}<parameter>${NC} means required, ${YELLOW}[parameter]${NC} means optional."
}
function cmd_about() {
	echo -e "===================================================\
			 \n   ██████╗ ██╗   ██╗██████╗ ███╗   ███╗███╗   ██╗  \
			 \n   ██╔══██╗██║   ██║██╔══██╗████╗ ████║████╗  ██║  \
			 \n   ██║  ██║██║   ██║██████╔╝██╔████╔██║██╔██╗ ██║  \
			 \n   ██║  ██║██║   ██║██╔═══╝ ██║╚██╔╝██║██║╚██╗██║  \
			 \n   ██████╔╝╚██████╔╝██║     ██║ ╚═╝ ██║██║ ╚████║  \
			 \n   ╚═════╝  ╚═════╝ ╚═╝     ╚═╝     ╚═╝╚═╝  ╚═══╝  \
			 \n                                ╗ made by neo3587 ╔\
			 \n           Source: ${CYAN}https://github.com/neo3587/dupmn${NC}\
			 \n   FAQs: ${CYAN}https://github.com/neo3587/dupmn/wiki/FAQs${NC}\
			 \n  BTC Donations: ${YELLOW}3F6J19DmD5jowwwQbE9zxXoguGPVR716a7${NC}\
			 \n==================================================="
	if [[ $(diff -q <(cat <(echo "$(curl -s https://raw.githubusercontent.com/neo3587/dupmn/master/dupmn.sh)")) <(cat /usr/bin/dupmn)) ]]; then 
		echo -e "\nUpdate available, use ${GREEN}bash dupmn_install.sh${NC} to install it\
			 \nif you deleted the ${YELLOW}dupmn_install.sh${NC} file, get it again with:\
			 \n${GREEN}wget -q https://raw.githubusercontent.com/neo3587/dupmn/master/dupmn_install.sh${NC}\n"
	fi
}


function main() {

	function load_profile() {
		# <$1 = profile_name> | [$2 = check_exec]

		if [[ ! -f ".dupmn/$1" ]]; then
			echo -e "${BLUE}$1${NC} profile hasn't been added"
			exit
		fi

		local -A prof=$(get_conf .dupmn/$1)
		local -A conf=$(get_conf .dupmn/dupmn.conf)

		local CMD_ARRAY=(COIN_NAME COIN_DAEMON COIN_CLI COIN_FOLDER COIN_CONFIG)
		for var in "${CMD_ARRAY[@]}"; do
			if [[ ! "${!prof[@]}" =~ "$var" || -z "${prof[$var]}" ]]; then
				echo -e "Seems like you modified something that was supposed to remain unmodified: ${MAGENTA}$var${NC} parameter should exists and have a assigned value in ${GREEN}.dupmn/$1${NC} file"
				echo -e "You can fix it by adding the ${BLUE}$1${NC} profile again"
				exit
			fi
		done
		if [[ ! "${!conf[@]}" =~ "$1" || -z "${conf[$1]}" || ! $(is_number "${conf[$1]}") ]]; then
			echo -e "Seems like you modified something that was supposed to remain unmodified: ${MAGENTA}$1${NC} parameter should exists and have a assigned number in ${GREEN}.dupmn/dupmn.conf${NC} file"
			echo -e "You can fix it by adding ${MAGENTA}$1=0${NC} to the .dupmn/dupmn.conf file (replace the number 0 for the number of nodes installed with dupmn using the ${BLUE}$1${NC} profile)"
			exit
		fi

		coin_name="${prof[COIN_NAME]}"
		coin_daemon="${prof[COIN_DAEMON]}"
		coin_cli="${prof[COIN_CLI]}"
		coin_folder="${prof[COIN_FOLDER]}"
		coin_config="${prof[COIN_CONFIG]}"
		rpc_port="${prof[RPC_PORT]}"
		dup_count=$((${conf[$1]}))
		exec_coin_daemon=$([[ -n ${prof[COIN_PATH]} ]] && echo ${prof[COIN_PATH]}$coin_daemon || which $coin_daemon)
		exec_coin_cli=$([[ -n ${prof[COIN_PATH]} ]] && echo ${prof[COIN_PATH]}$coin_cli || which $coin_cli)

		if [[ "$2" == "1" ]]; then
			if [[ ! -f "$exec_coin_daemon" ]]; then
				echo -e "Can't locate ${GREEN}$coin_daemon${NC}, it must be at ${CYAN}/usr/bin/${NC}, ${CYAN}/usr/local/bin/${NC} or in the defined path from \"COIN_PATH\""
				exit
			elif [[ ! -f "$exec_coin_cli" ]]; then
				echo -e "Can't locate ${GREEN}$coin_cli${NC}, it must be at ${CYAN}/usr/bin/${NC}, ${CYAN}/usr/local/bin/${NC} or in the defined path from \"COIN_PATH\""
				exit
			fi
		fi
	}
	function instance_valid() {
		# <$1 = profile_name> | <$2 = instance_number>

		if [[ ! $(is_number $2) ]]; then
			echo -e "${RED}$2${NC} is not a number"
			exit
		elif [[ $(($2)) = 0 ]]; then
			echo -e "Instance ${CYAN}0${NC} is a reference to the main masternode, not a duplicated one, can't modify this one"
			exit
		elif [[ $(($2)) -gt $dup_count ]]; then
			echo -e "Instance ${CYAN}$(($2))${NC} doesn't exists, there are only ${CYAN}$dup_count${NC} instances of ${BLUE}$1${NC}"
			exit
		fi
	}
	function ip_valid() {
		# <$1 = IPv4 or IPv6>

		function hexc() {
			if [[ "$1" != "" ]]; then
				printf "%x" $(printf "%d" "$(( 0x$1 ))")
			fi
		}

		ip=$1

		if [[ $(echo $(get_ips 4) | grep -w "$ip") ]]; then
			return
		elif [[ "$1" =~ ^[0-9a-f:]+$ && $(echo $1 | grep -o "::" | wc -l) -le 1 ]]; then

			echo $ip | grep -qs "^:" && ip="0${ip}"

			if echo $ip | grep -qs "::"; then
				ip=$(echo $ip | sed "s/::/$(echo ":::::::::" | sed "s/$(echo $ip | sed 's/[^:]//g')//" | sed 's/:/:0/g')/")
			fi

			set $(echo $ip | grep -o "[0-9a-f]\+")

			ip=$(echo "$(hexc $1):$(hexc $2):$(hexc $3):$(hexc $4):$(hexc $5):$(hexc $6):$(hexc $7):$(hexc $8)" | sed "s/:0:/::/")
			while [[ "$ip" =~ "::0:" ]]; do
				ip=$(echo $ip | sed 's/::0:/::/g')
			done
			while [[ "$ip" =~ ":::" ]]; do
				ip=$(echo $ip | sed 's/:::/::/g')
			done

			if [[ $(echo $(get_ips 6) | grep -w "$ip") ]]; then
				ip="[$ip]"
				return
			fi
		fi

		echo -e "$ip ip cannot be found or is invalid, use ${GREEN}dupmn iplist${NC} to check your current available IPs"
		exit
	}

	if [[ -z "$1" ]]; then
		echo -e "No command inserted, use ${YELLOW}dupmn help${NC} to see all the available commands"
		exit
	fi

	case "$1" in
		"profadd")
			if [[ -z "$3" ]]; then
				echo -e "${YELLOW}dupmn profadd <prof_file> <coin_name>${NC} requires a profile file and a new profile name as parameters"
				exit
			fi
			cmd_profadd "$2" "$3"
			;;
		"profdel")
			if [[ -z "$2" ]]; then
				echo -e "${YELLOW}dupmn profadd <prof_name>${NC} requires a profile name as parameter"
				exit
			fi
			load_profile "$2"
			cmd_profdel "$2"
			;;
		"install")
			if [[ -z "$2" ]]; then
				echo -e "${YELLOW}dupmn install <coin_name> [copy]${NC} requires a profile name of an added profile as a parameter"
				exit
			fi
			load_profile "$2" "1"
			cmd_install "$2" $(($dup_count+1)) "$3"
			;;
		"reinstall")
			if [[ -z "$3" ]]; then
				echo -e "${YELLOW}dupmn reinstall <coin_name> <number> [copy]${NC} requires a profile name and a instance as parameters"
				exit
			fi
			load_profile "$2" "1"
			instance_valid "$2" "$3"
			cmd_reinstall "$2" $(($3)) "0" "$4"
			;;
		"uninstall")
			if [[ -z "$3" ]]; then
				echo -e "${YELLOW}dupmn uninstall <coin_name> <param>${NC} requires a profile name and a number (or all) as parameters"
				exit
			fi
			load_profile "$2"
			if [[ "$3" != "all" ]]; then
				instance_valid "$2" "$3"
				cmd_uninstall "$2" $(($3))
			else
				cmd_uninstall "$2" "$3"
			fi
			;;
		"ipinstall")
			if [[ -z "$3" ]]; then
				echo -e "${YELLOW}dupmn ipinstall <coin_name> <ip> [copy]${NC} requires a profile name of an added profile and a IP as a parameters"
				exit
			fi
			load_profile "$2" "1"
			ip_valid "$3"
			cmd_ipinstall "$2" $(($dup_count+1)) "$4"
			;;
		"ipreinstall")
			if [[ -z "$4" ]]; then
				echo -e "${YELLOW}dupmn ipreinstall <coin_name> <number> <ip> [copy]${NC} requires a profile name, instance and a IP as parameters"
				exit
			fi
			load_profile "$2" "1"
			instance_valid "$2" "$3"
			ip_valid "$4"
			cmd_reinstall "$2" $(($3)) "1" "$5"
			;;
		"iplist")
			cmd_iplist
			;;
		"rpcchange")
			if [[ -z "$3" ]]; then
				echo -e "${YELLOW}dupmn rpcchange <prof_name> <number> [port]${NC} requires a profile name, instance number and optionally a port number as parameters"
				exit
			fi
			load_profile "$2" "1"
			instance_valid "$2" "$3"
			cmd_rpcchange "$2" $(($3)) "$4"
			;;
		"systemctlall")
			if [[ -z "$3" ]]; then
				echo -e "${YELLOW}dupmn systemctlall <prof_name> <command>${NC} requires a profile name and a command as parameters"
				exit
			fi
			load_profile "$2"
			cmd_systemctlall "$2" "$3"
			;;
		"list")
			[[ -z "$2" ]] || load_profile "$2"
			cmd_list $2
			;;
		"swapfile")
			if [[ -z "$2" ]]; then
				echo -e "${YELLOW}dupmn swapfile <size_in_mbytes>${NC} requires a number as parameter"
				exit
			fi
			cmd_swapfile "$2"
			;;
		"help")
			cmd_help
			;;
		"about")
			cmd_about
			;;
		*)
			echo -e "Unrecognized parameter: ${RED}$1${NC}"
			echo -e "use ${YELLOW}dupmn help${NC} to see all the available commands"
			;;
	esac
}

main $@

