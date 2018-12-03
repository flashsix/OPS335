#!/bin/bash

### ALL INPUT BEFORE CHECKING #### -------------------

        
        ### INPUT from USER ###
clear
read -p "What is your Seneca username: " username
read -p "What is your FULL NAME: " fullname
read -s -p "Type your normal password: " password && echo
IP=$(cat /var/named/mydb-for-* | grep ^vm1 | head -1 | awk '{print $4}')
digit=$(cat /var/named/mydb-for-* | grep ^vm2 | head -1 | awk '{print $4}' | cut -d. -f3)

domain="$username.ops"
vms_name=(vm1 vm2 vm3)   
vms_ip=(192.168.$digit.2 192.168.$digit.3 192.168.$digit.4)    
        
        #### Create Hash Table -------------------------------
        
for (( i=0; i<${#vms_name[@]};i++ ))
do
    declare -A dict
    dict+=(["${vms_name[$i]}"]="${vms_ip[$i]}")
done
############### CHECKING ALL THE REQUIREMENT BEFORE RUNNING THE SCRIPT ############################
function require {
    function check() {
        if eval $1
        then
            echo -e "\e[32mOK. GOOD \e[0m"
        else
            echo
                echo
                echo -e "\e[0;31mWARNING\e[m"
                echo
                echo
                zenity --error --title="An Error Occurred" --text=$2
                echo
                exit 1
        fi  
    }
        
        ### 1.Run script by Root ---------------------------------------------

        if [ `id -u` -ne 0 ]
        then
            echo "Must run this script by root" >&2
            exit 2
        fi

        ### 2.Backing up before runnning the script ------------------

        echo -e "\e[1;31m--------WARNING----------"
        echo -e "\e[1mBackup your virtual machine to run this script \e[0m"
        echo
        if zenity --question --title="BACKUP VIRTUAL MACHINES" --text="DO YOU WANT TO MAKE A BACKUP"
        then
            echo -e "\e[1;35mBacking up in process. Wait... \e[0m" >&2
            for shut in $(virsh list --name)  ## --- shutdown vms to backup --- ###
            do
                virsh shutdown $shut
                while virsh list | grep -iqs $shut
                do
                    echo $shut is being shutdown to backup. Wait
                    sleep 3
                done
            done
            yum install pv -y  > /dev/null 2>&1
            
            for bk in $(ls /var/lib/libvirt/images/ | grep -v vm* | grep \.qcow2$)
            do
                echo "Backing up $bk"
                mkdir -p /backup/full 2> /dev/null
                pv /var/lib/libvirt/images/$bk | gzip | pv  > /backup/full/$bk.backup.gz
            done
        fi

        ### 3.Checking VMs need to be clone and status ----------------------------------
    function clone-machine {
        echo -e "\e[1;35mChecking clone machine\e[m"
        count=0
        for vm in ${vms_name[@]}
        do 
            if ! virsh list --all | grep -iqs $vm
            then
                echo "$vm need to be created"
                echo
                echo
                count=1
            fi
        done
        #----------------------------------------# Setup cloyne to be cloneable
        if [ $count -gt 0 ]
        then
            echo -e "\e[35mStart cloning machines\e[m"
            echo
            echo -e "\e[1;32mCloning in progress...\e[m"
            virsh start cloyne 2> /dev/null
            while ! eval "ping 172.17.15.100 -c 5 > /dev/null" 
            do
                echo "Cloyne machine is starting"
                sleep 3
            done
            sleep 5
            ## Set clone-machine configuration before cloning
            check "ssh -o ConnectTimeout=8 172.17.15.100 ls > /dev/null" "Can not SSH to Cloyne, check and run the script again"
            intcloyne=$(ssh 172.17.15.100 '( ip ad | grep -B 2 172.17.15 | head -1 | cut -d" " -f2 | cut -d: -f1 )' )  #### grab interface infor (some one has ens3)
            maccloyne=$(ssh 172.17.15.100 grep ".*HWADDR.*" /etc/sysconfig/network-scripts/ifcfg-$intcloyne) #### grab mac address
            check "ssh 172.17.15.100 grep -v -e '.*DNS.*' -e 'DOMAIN.*' /etc/sysconfig/network-scripts/ifcfg-$intcloyne > ipconf.txt" "File or directory not exist"
            echo "DNS1="172.17.15.2"" >> ipconf.txt
            echo "DNS2="172.17.15.3"" >> ipconf.txt
            echo "PEERDNS=no" >> ipconf.txt
            echo "DOMAIN=towns.ontario.ops" >> ipconf.txt
            sed -i 's/'${maccloyne}'/#'${maccloyne}'/g' ipconf.txt 2> /dev/null  #comment mac address in ipconf.txt file
            check "scp ipconf.txt 172.17.15.100:/etc/sysconfig/network-scripts/ifcfg-$intcloyne > /dev/null" "Can not copy ipconf to Cloyne"
            rm -rf ipconf.txt > /dev/null
            sleep 2
            echo -e "\e[32mCloyne machine info has been collected\e[m"
            virsh suspend cloyne            
        
            #---------------------------# Start cloning
            for clonevm in ${!dict[@]} # Key (name vm)
            do 
                if ! virsh list --all | grep -iqs $clonevm
                then
                    echo -e "\e[1;35mCloning $clonevm \e[m"
                    virt-clone --auto-clone -o cloyne --name $clonevm
                #-----Turn on cloned vm without turning on cloyne machine
                virsh start $clonevm
                while ! eval "ping 172.17.15.100 -c 5 > /dev/null" 
                do
                    echo "Clonning machine is starting"
                    sleep 3
                done
                #------ get new mac address
                newmac=$(virsh dumpxml $clonevm | grep "mac address" | cut -d\' -f2)
                #-----Replace mac and ip, hostname
                ssh 172.17.15.100 "sed -i 's/.*HW.*/HWADDR\='${newmac}'/g' /etc/sysconfig/network-scripts/ifcfg-$intcloyne" ## change mac
                ssh 172.17.15.100 "echo $clonevm.towns.ontario.ops > /etc/hostname "  #change host name
                ssh 172.17.15.100 "sed -i 's/'172.17.15.100'/'${dict[$clonevm]}'/' /etc/sysconfig/network-scripts/ifcfg-$intcloyne" #change ip
                echo
                echo -e "\e[32mCloning Done $clonevm\e[m"
                ssh 172.17.15.100 init 6
                fi
            done
                #------------------# reset cloyne machine
                oldmac=$(virsh dumpxml cloyne | grep "mac address" | cut -d\' -f2)
                virsh resume cloyne > /dev/null 2>&1
                while ! eval "ping 172.17.15.100 -c 5 > /dev/null" 
                do
                    echo "Cloyne machine is starting"
                    sleep 3
                done
                sleep 5
                ssh 172.17.15.100 "sed -i 's/.*HW.*/'${oldmac}'/g' /etc/sysconfig/network-scripts/ifcfg-$intcloyne"
                ssh 172.17.15.100 init 6
        fi
    }       
    clone-machine

    ########################################
    echo -e "\e[1;35mChecking VMs status\e[m"
    for vm in ${!dict[@]}
    do 
        if ! virsh list | grep -iqs $vm
        then
            virsh start $vm > /dev/null 2>&1
            while ! eval "ping ${dict[$vm]} -c 5 > /dev/null" 
            do
                echo -e "\e[1;34mMachine $vm is turning on \e[0m" >&2
                sleep 3
            done
        fi
    done
    
    ### 4.SSH and Pinging and Update Check ------------------------------------
    echo -e "\e[1;35mRestarting Named\e[m"
    systemctl restart named
    echo -e "\e[32mRestarted Done \e[m"

    check "ping -c 3 google.ca > /dev/null" "Host machine can not ping GOOGLE.CA, check INTERNET connection then run the script again"
        
    for ssh_vm in ${!dict[@]} ## -- Checking VMS -- ## KEY
    do
    check "ssh -o ConnectTimeout=5 -oStrictHostKeyChecking=no ${dict[$ssh_vm]} ls > /dev/null" "Can not SSH to $ssh_vm, check and run the script again "
    check "ssh ${dict[$ssh_vm]} ping -c 3 google.ca > /dev/null" "Can not ping GOOGLE.CA from $ssh_vm, check internet connection then run the script again"
    check "ssh ${dict[$ssh_vm]} yum update -y" "Can not YUM UPDATE from $ssh_vm"
    done
    
    ### 5.Checking jobs done from Assignment 1 -------------------------

    #check "ssh ${vms_ip[0]} host ${vms_name[0]}.$domain > /dev/null 2>&1" "Name service in ${vms_name[0]} is not working"
    
}
require
virsh start vm1 > /dev/null 2>&1
virsh start vm2 > /dev/null 2>&1
virsh start vm3 > /dev/null 2>&1
list_vms="vm1 vm2 vm3"
read -p "What is your Seneca username: " username
read -p "What is your IP Address of VM1: " IP
digit=$( echo "$IP" | awk -F. '{print $3}' )
domain=$username.ops

##Checking running script by root###
if [ `id -u` -ne 0 ]
then
	echo "Must run this script by root" >&2
	exit 1 
fi

#### Checking Internet Connection###
check "ping -c 3 google.ca > /dev/null" "Can not ping GOOGLE.CA, check your Internet connection "

## Installing BIND Package ######
echo 
echo "############ Installing DNS ###########"
echo 
check "yum install bind* -y" "Can not use Yum to install"
systemctl start named
systemctl enable named
echo -e "\e[32mInstalling Done\e[m"

### Making DNS configuration file ####
cat > /etc/named.conf << EOF
options {
        directory "/var/named/";
        allow-query {127.0.0.1; 192.168.$digit.0/24;};
        forwarders { 192.168.40.2; };
};
zone "." IN {
	type hint;
        file "named.ca";
};
zone "localhost" {
        type master;
        file "named.localhost";
};
zone "$username.ops" {
        type master;
        file "mydb-for-$username-ops";
};
zone "$digit.168.192.in-addr.arpa." {
        type master;
        file "mydb-for-192.168.$digit";
};
EOF

##### Making forward zone file ####

cat > /var/named/mydb-for-$username-ops << EOF
\$TTL    3D
@       IN      SOA     host.$username.ops.      hostmaster.$username.ops.(
                2018042901       ; Serial
                8H      ; Refresh
                2H      ; Retry
                1W      ; Expire
                1D      ; Negative Cache TTL
);
@       IN      NS      host.$username.ops.
host    IN      A       192.168.$digit.1
vm1		IN		A 		192.168.$digit.2
vm2		IN		A 		192.168.$digit.3
vm3		IN		A 		192.168.$digit.4

EOF

##### Making reverse zone file  #####

cat > /var/named/mydb-for-192.168.$digit << EOF

\$TTL    3D
@       IN      SOA     host.$username.ops.      hostmaster.$username.ops.(
                2018042901       ; Serial
                8H      ; Refresh
                2H      ; Retry
                1W      ; Expire
                1D      ; Negative Cache TTL
);
@       IN      NS      host.$username.ops.
1       IN      PTR     host.$username.ops.
2		IN		PTR		vm1.$username.ops.
3		IN		PTR		vm2.$username.ops.
4		IN		PTR		vm3.$username.ops.

EOF
	
echo	
echo -e "###\e[32mFiles Added Done\e[m###"
echo
#### Adding DNS and DOMAIN ####
systemctl stop NetworkManager
systemctl disable NetworkManager

if [ ! -f /etc/sysconfig/network-scripts/ifcfg-ens33.backup ]
then
	cp /etc/sysconfig/network-scripts/ifcfg-ens33 /etc/sysconfig/network-scripts/ifcfg-ens33.backup
fi
grep -v -i -e "^DNS.*" -e "^DOMAIN.*" /etc/sysconfig/network-scripts/ifcfg-ens33 > ipconf.txt
scp ipconf.txt /etc/sysconfig/network-scripts/ifcfg-ens33
echo "DNS1=192.168.$digit.1" >> /etc/sysconfig/network-scripts/ifcfg-ens33
echo "DOMAIN=$username.ops" >> /etc/sysconfig/network-scripts/ifcfg-ens33
echo host.$domain > /etc/hostname
rm -rf ipconf.txt

#### Adding rules in IPtables ####
grep -v ".*INPUT.*dport 53.*" /etc/sysconfig/iptables > iptables.txt
scp iptables.txt /etc/sysconfig/iptables
iptables -I INPUT -p tcp --dport 53 -j ACCEPT
iptables -I INPUT -p udp --dport 53 -j ACCEPT
iptables-save > /etc/sysconfig/iptables
service iptables save
rm -rf iptables.txt

### Remove hosts in the previous lab ###
grep -v -i -e "vm.*" /etc/hosts > host.txt
scp host.txt /etc/hosts
echo "search $domain" > /etc/resolv.conf
echo "nameserver 192.168.${digit}.1" >> /etc/resolv.conf


systemctl restart iptables
systemctl restart named


clear
echo	
echo -e "###\e[32mConfiguration Done\e[m###"
echo

### CONFIG USERNAME, HOSTNAME, DOMAIN VM1,2,3
for (( i=2;i<=4;i++ ))
do
intvm=$( ssh 192.168.$digit.${i} '( ip ad | grep -B 2 192.168.$digit | head -1 | cut -d" " -f2 | cut -d: -f1 )' )
ssh 192.168.$digit.${i} "echo vm$(($i-1)).$domain > /etc/hostname"
check "ssh 192.168.$digit.${i} grep -v -e '^DNS.*' -e 'DOMAIN.*' /etc/sysconfig/network-scripts/ifcfg-$intvm > ipconf.txt" "File or directory not exist"
echo "DNS1="192.168.$digit.1"" >> ipconf.txt
echo "PEERDNS=no" >> ipconf.txt
echo "DOMAIN=$domain" >> ipconf.txt
check "scp ipconf.txt 192.168.$digit.${i}:/etc/sysconfig/network-scripts/ifcfg-$intvm > /dev/null" "Can not copy ipconf to VM${i}"
rm -rf ipconf.txt > /dev/null
ssh 192.168.$digit.${i} "echo "search $domain" > /etc/resolv.conf"
ssh 192.168.$digit.${i} "echo "nameserver 192.168.${digit}.1" >> /etc/resolv.conf"
done

echo -e "\e[1;32m COMPLETED\e[m"







