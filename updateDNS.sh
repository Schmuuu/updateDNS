#!/bin/bash
# @requires awk, curl, grep, sed, tr.

## START EDIT HERE.

api_key_file="/root/.secrets/hosting_api_key.ini"
domain_file="/root/.secrets/hostingDE_fqdn.txt"
ip6_interface="enp1s0"
hoster="Hosting.de"
storedIpAddresses="/root/.secrets/${hoster}_latest_ip_updates.txt"
verbose=true
curl_timeout="90"
api_url="https://secure.hosting.de/api/dns/v1/json/changeContent"
url_ext_ip="http://ipv4.icanhazip.com"
url_ext_ip2="http://ifconfig.me/ip"

## END EDIT.
##
###################################################################

update_only=false
NO_FILE_UPDATE=false
ipAddressesToStore=""

echov()
{
  if [ $verbose == true ]; then
    if [ $# == 1 ]; then
      echo "$1"
    else
      printf "$@"
    fi
  fi
}

get_external_ip()
{
  ip_address="$(curl -s --connect-timeout $curl_timeout $url_ext_ip | sed -e 's/.*Current IP Address: //' -e 's/<.*$//' | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')"
  if [ -z "$ip_address" ]; then
    ip_address="$(curl -s --connect-timeout $curl_timeout $url_ext_ip2 | grep -Eo '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}')"
    if [ -z "$ip_address" ]; then
      return 1
    fi
  else
    return 0
  fi
}

get_global_ip6()
{
  # 
  ip6_address="$(ip -6 addr show $ip6_interface | grep 'scope global' | grep -v 'deprecated' | grep -oE '([0-9a-fA-F]+:+[0-9a-fA-F]+)+' | grep -Ev '^fd00|^fe80')"
  if [ -z "$ip6_address" ]; then
    return 1
  # check if it is a single IP6 addr. Fixes a rare issue where an IF has two IP6 addresses (old and new) for short period of time
  elif [ `echo $ip6_address | tr -dc ':' | wc -c` -gt 7 ]; then
    return 1
  else
    return 0
  fi
}


# start.
echov "==============================================================="
echov "* Updating DNS settings: $(date +"%Y-%m-%d %H:%M:%S")"

if [ ! -r "${api_key_file}" ]; then
  echo "! API key file ${api_key_file} does not exist or is not readable"
fi
api_key=`cat ${api_key_file}`

echov "* Fetching external IP from: $url_ext_ip"
get_external_ip;
if [ $? -ne 0 ] ; then
  echo "! Unable to extract external IP address"
  exit 1
fi

echov "* Fetching global IPv6 from interface: $ip6_interface"
get_global_ip6 "$ip6_interface"
if [ $? -ne 0 ] ; then
  echo "! Unable to extract global IPv6 address"
  exit 1
fi


if [[ -r "${storedIpAddresses}" ]]; then
  updatedAddressesFromFile=`cat $storedIpAddresses`
  if [[ $updatedAddressesFromFile =~ $ip_address ]] && [[ $updatedAddressesFromFile =~ $ip6_address ]]; then
    echov "* Current IP addresses have already been updated at ${hoster}"
    echov "* Nothing to do here. Exiting..."
    exit 0
  fi

  if [[ `echo $updatedAddressesFromFile | cut -d ";" -f1` =~ "." ]]; then
    old_ip_address=`echo $updatedAddressesFromFile | cut -d ";" -f1`
    old_ip6_address=`echo $updatedAddressesFromFile | cut -d ";" -f2`
  else
    old_ip_address=`echo $updatedAddressesFromFile | cut -d ";" -f2`
    old_ip6_address=`echo $updatedAddressesFromFile | cut -d ";" -f1`
  fi
else
  echo "! There is no file storing the latest IP addresses updated with ${hoster}! Need to lookup IPs."

  if [ ! -r "${domain_file}" ]; then
    echo "! Domain file ${domain_file} containing FQDN does not exist or is not readable. File required for nslookup."
    exit 1
  fi

  # TODO: Request current IP from HostingDE via API rather than using nslookup and modify script accordingly in this else block
  #       For now there could be an issue when nslookup doesn't provide the IPs really configured at ${hoster} due to DNS caching
  #       issues for example. The local temp file would then be updated with wrong IP addresses and will never run successful again.
  #       Manual steps to edit the file for storedIpAddresses would be required then.
  # 
  #       But later ...
  domain=`cat ${domain_file}`
  addresses=`nslookup ${domain} | grep Address | tail --lines=+2 | awk '{print $2}'`
  old_ip_address=`echo $addresses | grep "\."`
  old_ip6_address=`echo $addresses | grep ":"`

  if [[ $old_ip_address =~ $ip_address ]] && [[ $old_ip6_address =~ $ip6_address ]]; then
    echov "* Current IP addresses seem already been updated at ${hoster}"
    echov "* Continue script to write file ${storedIpAddresses}."
  fi
fi

if [[ -z "$old_ip_address" || -z "$old_ip6_address" ]]; then
  echo "! At least on of the old IP addresses is empty. Check File!"
  NO_FILE_UPDATE=true
fi


if [[ "$ip_address" != "$old_ip_address" ]]; then

  echov "* old v4: $old_ip_address - new v4: $ip_address"

  data=`curl -s -X POST --connect-timeout $curl_timeout -H "Content-Type: application/json" --data "{\"authToken\":\"$api_key\",\"recordType\":\"A\",\"oldContent\":\"$old_ip_address\",\"newContent\": \"$ip_address\",\"includeTemplates\": false,\"includeSubAccounts\": true}" $api_url`
  if [ -z "$data" ] || ( [[ "$data" != *"status\": \"pending"* ]] && [[ "$data" != *"status\": \"success"* ]] ); then
    echov "* Update to IP $ip_address from old IP $old_ip_address FAILED!"
    ipAddressesToStore="${ipAddressesToStore}${old_ip_address};"
  else
    echov "* Update to IP $ip_address from old IP $old_ip_address successfull"
    ipAddressesToStore="${ipAddressesToStore}${ip_address};"
  fi
else
  ipAddressesToStore="${ipAddressesToStore}${ip_address};"
fi

# accessing the API with two requests can result in double SOA entries and therefor corrupt the DNS entry
# Therefor a little pause at this point
sleep 15

if [[ "$ip6_address" != "$old_ip6_address" ]]; then

  echov "* old v6: $old_ip6_address - new v6: $ip6_address"

  data=`curl -s -X POST --connect-timeout $curl_timeout -H "Content-Type: application/json" --data "{\"authToken\":\"$api_key\",\"recordType\":\"AAAA\",\"oldContent\":\"$old_ip6_address\",\"newContent\": \"$ip6_address\",\"includeTemplates\": false,\"includeSubAccounts\": true}" $api_url`
  if [ -z "$data" ] || ( [[ "$data" != *"status\": \"pending"* ]] && [[ "$data" != *"status\": \"success"* ]] ); then
    echov "* Update to IP $ip6_address from old IP $old_ip6_address FAILED!"
    ipAddressesToStore="${ipAddressesToStore}${old_ip6_address};"
  else
    echov "* Update to IP $ip6_address from old IP $old_ip6_address successfull"
    ipAddressesToStore="${ipAddressesToStore}${ip6_address};"
  fi
else
  ipAddressesToStore="${ipAddressesToStore}${ip6_address};"
fi

touch $storedIpAddresses;
if [[ ! -f "${storedIpAddresses}" ]]; then
  echo "! Cannot create file to store latest updated IP addresses!"
  exit 1
fi

if [[ ! $ipAddressesToStore =~ "." || ! $ipAddressesToStore =~ ":" ]]; then
  NO_FILE_UPDATE=true
fi

if [[ $NO_FILE_UPDATE == true ]]; then
  echo "! Something went wrong; not updating the IP addresses in file $storedIpAddresses."
  exit 1
else
  echo "$ipAddressesToStore" > $storedIpAddresses
fi

echov "\n* IP address(es) successfully added/updated.\n" ""

exit 0
