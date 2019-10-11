IP_ADDR=$1
C_NAME=$2
# Try to login with the SSH key

ssh root@${IP_ADDR} 'uptime'
if [ $? -eq 0 ]; then
    echo SSH Test OK
else
    echo SSH Test Failed. Please make sure the IP is correct, your server is on and the server has your SSH public key installed.
    exit 1
fi

ssh openvpn@${IP_ADDR} '~/EasyRSA-3.0.4/easyrsa gen-req '"${C_NAME}"' nopass'
ssh openvpn@${IP_ADDR} 'cp ~/pki/private/'"${C_NAME}"'.key ~/client-configs/keys/'
scp openvpn@${IP_ADDR}:/home/openvpn/pki/reqs/${C_NAME}.req /tmp
cd ~/EasyRSA-3.0.4/
./easyrsa import-req /tmp/${C_NAME}.req ${C_NAME}
./easyrsa sign-req client ${C_NAME}
scp pki/issued/${C_NAME}.crt openvpn@${IP_ADDR}:/tmp
ssh openvpn@${IP_ADDR} 'cp /tmp/'"${C_NAME}"'.crt ~/client-configs/keys/'
ssh root@${IP_ADDR} '/home/openvpn/client-configs/make_config.sh '"${C_NAME}"
ssh openvpn@${IP_ADDR} 'ls ~/client-configs/files'
echo Profile ${C_NAME} created
scp openvpn@${IP_ADDR}:/home/openvpn/client-configs/files/${C_NAME}.ovpn ~/

