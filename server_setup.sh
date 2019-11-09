#!/bin/bash
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" >/dev/null 2>&1 && pwd )"

# Suppose a new droplet has been created, and the SSH public key has been added to the droplet
# Get the IP address from the argument
IP_ADDR=$1

# Try to login with the SSH key
ssh root@${IP_ADDR} 'uptime'
if [ $? -eq 0 ]; then
    echo SSH Test OK
else
    echo SSH Test Failed. Please make sure the IP is correct, your server is on and the server has your SSH public key installed.
    exit 1
fi
# create a new user openvpn
echo Creating a new user \'openvpn\'. Note down the password.
ssh -t root@${IP_ADDR} 'adduser openvpn'
ssh root@${IP_ADDR} 'usermod -aG sudo openvpn'
ssh root@${IP_ADDR} 'ufw app list && ufw allow OpenSSH && ufw enable'
ssh root@${IP_ADDR} 'ufw status && rsync --archive --chown=openvpn:openvpn ~/.ssh /home/openvpn'


# Install and configure EasyRSA on local machine
if [ ! -e EasyRSA-3.0.4.tgz ]
then
    wget -P ~/ https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.4/EasyRSA-3.0.4.tgz
fi
cd ~/
tar xvf EasyRSA-3.0.4.tgz
cd ~/EasyRSA-3.0.4/
cp vars.example vars
sed -i 's/^#set_var EASYRSA_REQ_COUNTRY/set_var EASYRSA_REQ_COUNTRY/' vars
sed -i 's/^#set_var EASYRSA_REQ_PROVINCE/set_var EASYRSA_REQ_PROVINCE/' vars
sed -i 's/^#set_var EASYRSA_REQ_CITY/set_var EASYRSA_REQ_CITY/' vars
sed -i 's/^#set_var EASYRSA_REQ_ORG/set_var EASYRSA_REQ_ORG/' vars
sed -i 's/^#set_var EASYRSA_REQ_EMAIL/set_var EASYRSA_REQ_EMAIL/' vars
sed -i 's/^#set_var EASYRSA_REQ_OU/set_var EASYRSA_REQ_OU/' vars
./easyrsa init-pki
echo You will be asked to confirm the common name of the CA. Just press ENTER to use the default one.
./easyrsa build-ca nopass

# Install OpenVPN and EasyRSA on the server
ssh root@${IP_ADDR} 'apt update && apt install -y openvpn'
ssh openvpn@${IP_ADDR} 'wget -P ~/ https://github.com/OpenVPN/easy-rsa/releases/download/v3.0.4/EasyRSA-3.0.4.tgz && cd ~/ && tar xvf EasyRSA-3.0.4.tgz'
ssh openvpn@${IP_ADDR} '/home/openvpn/EasyRSA-3.0.4/easyrsa init-pki'

# Generate a certificate request and sign the certificate for the server
ssh openvpn@${IP_ADDR} '/home/openvpn/EasyRSA-3.0.4/easyrsa gen-req server nopass'
ssh root@${IP_ADDR} 'cp /home/openvpn/pki/private/server.key /etc/openvpn/'
scp openvpn@${IP_ADDR}:/home/openvpn/pki/reqs/server.req /tmp
cd EasyRSA-3.0.4/
./easyrsa import-req /tmp/server.req server
echo Type yes and ENTER to confirm the request detail.
./easyrsa sign-req server server
scp pki/issued/server.crt openvpn@${IP_ADDR}:/tmp
scp pki/ca.crt openvpn@${IP_ADDR}:/tmp
ssh root@${IP_ADDR} 'cp /tmp/{server.crt,ca.crt} /etc/openvpn/'
ssh openvpn@${IP_ADDR} '~/EasyRSA-3.0.4/easyrsa gen-dh && openvpn --genkey --secret ~/EasyRSA-3.0.4/ta.key'
ssh root@${IP_ADDR} 'cp /home/openvpn/EasyRSA-3.0.4/ta.key /etc/openvpn/ && cp /home/openvpn/pki/dh.pem /etc/openvpn/'

# Configure the OpenVPN server
ssh openvpn@${IP_ADDR} 'mkdir -p ~/client-configs/keys && chmod -R 700 ~/client-configs && cp ~/EasyRSA-3.0.4/ta.key ~/client-configs/keys/'
ssh root@${IP_ADDR} 'cp /etc/openvpn/ca.crt /home/openvpn/client-configs/keys/ && cp /usr/share/doc/openvpn/examples/sample-config-files/server.conf.gz /etc/openvpn/ && gzip -d /etc/openvpn/server.conf.gz'
ssh root@${IP_ADDR} 'sed -i "/^cipher AES-256-CBC/a auth SHA256" /etc/openvpn/server.conf && sed -i "s/^dh dh2048.pem/dh dh.pem/g" /etc/openvpn/server.conf && sed -i "s/^;user nobody/user nobody/g" /etc/openvpn/server.conf && sed -i "s/^;group nogroup/group nogroup/g" /etc/openvpn/server.conf && sed -i "s/^;push \"redirect-gateway def1 bypass-dhcp\"/push \"redirect-gateway def1 bypass-dhcp\"/g" /etc/openvpn/server.conf && sed -i "s/^;push \"dhcp-option DNS 208.67.222.222\"/push \"dhcp-option DNS 208.67.222.222\"/g" /etc/openvpn/server.conf && sed -i "s/^;push \"dhcp-option DNS 208.67.220.220\"/push \"dhcp-option DNS 208.67.220.220\"/g" /etc/openvpn/server.conf && sed -i "s/^port 1194/port 443/g" /etc/openvpn/server.conf && sed -i "s/^proto udp/proto tcp/g" /etc/openvpn/server.conf && sed -i "s/^explicit-exit-notify 1/explicit-exit-notify 0/g" /etc/openvpn/server.conf'

# Configure the network
ssh root@${IP_ADDR} 'sed -i "s/^#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g" /etc/sysctl.conf && sysctl -p'
ETH=$(ssh openvpn@${IP_ADDR} '(ip route | grep default) | grep -o -P "(?<=dev ).*(?= proto)"')
ssh root@${IP_ADDR} 'sed -i "1s/^/*nat\n:POSTROUTING ACCEPT [0:0]\n-A POSTROUTING -s 10.8.0.0\/8 -o '"${ETH}"' -j MASQUERADE\nCOMMIT\n/" /etc/ufw/before.rules && sed -i "s/^DEFAULT_FORWARD_POLICY=\"DROP\"/DEFAULT_FORWARD_POLICY=\"ACCEPT\"/g" /etc/default/ufw' 
ssh root@${IP_ADDR} 'ufw allow 443/tcp && ufw allow OpenSSH && ufw disable && ufw enable'


# Start the OpenVPN server
ssh root@${IP_ADDR} 'systemctl start openvpn@server && systemctl status openvpn@server && ip addr show tun0 && systemctl enable openvpn@server'


# Create client configuration infrastructure
ssh openvpn@${IP_ADDR} 'mkdir -p ~/client-configs/files && cp /usr/share/doc/openvpn/examples/sample-config-files/client.conf ~/client-configs/base.conf'
ssh openvpn@${IP_ADDR} 'sed -i "s/my-server-1 1194/'"${IP_ADDR}"' 443/g" ~/client-configs/base.conf && sed -i "s/proto udp/proto tcp/g" ~/client-configs/base.conf && sed -i "s/;user nobody/user nobody/g" ~/client-configs/base.conf && sed -i "s/;group nogroup/group nogroup/g" ~/client-configs/base.conf && sed -i "s/ca ca.crt/#ca ca.crt/g" ~/client-configs/base.conf && sed -i "s/cert client.crt/#cert client.crt/g" ~/client-configs/base.conf && sed -i "s/key client.key/#key client.key/g" ~/client-configs/base.conf && sed -i "s/tls-auth ta.key 1/#tls-auth ta.key 1/g" ~/client-configs/base.conf'
ssh openvpn@${IP_ADDR} 'sed -i "/^cipher AES-256-CBC/a auth SHA256" ~/client-configs/base.conf'
ssh openvpn@${IP_ADDR} 'sed -i "\$akey-direction 1" ~/client-configs/base.conf'
ssh openvpn@${IP_ADDR} 'sed -i "\$a# script-security 2\n# up /etc/openvpn/update-resolv-conf\n# down /etc/openvpn/update-resolv-conf" ~/client-configs/base.conf'
scp ${DIR}/make_config.sh openvpn@${IP_ADDR}:/home/openvpn/client-configs/
ssh openvpn@${IP_ADDR} 'chmod 700 ~/client-configs/make_config.sh'
