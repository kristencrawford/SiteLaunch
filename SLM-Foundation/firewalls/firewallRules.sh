#!/bin/bash

#
#     _____            _                    _     _       _      _____ _                 _
#     /  __ \          | |                  | |   (_)     | |    /  __ \ |               | |
#     | /  \/ ___ _ __ | |_ _   _ _ __ _   _| |    _ _ __ | | __ | /  \/ | ___  _   _  __| |
#     | |    / _ \ '_ \| __| | | | '__| | | | |   | | '_ \| |/ / | |   | |/ _ \| | | |/ _` |
#     | \__/\  __/ | | | |_| |_| | |  | |_| | |___| | | | |   <  | \__/\ | (_) | |_| | (_| |
#      \____/\___|_| |_|\__|\__,_|_|   \__, \_____/_|_| |_|_|\_\  \____/_|\___/ \__,_|\__,_|
#                                        __/ |
#                                       |___/
#
#    firewallRules.sh
#    Kristen Crawford <kristen.crawford@centurylink.com>
#
#    Add firewall rules (Section 3 of CLC Provisioning)
#
#### Changelog
#
##   2015.12.15 <kristen.crawford@centurylink.com>
## - Initial release


## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ADD_DC="${2}"

#Control Information
ENDPOINT="api.ctl.io"
V2AUTH="{ \"username\": \" <v2 user> \", \"password\": \" <v2 pass> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 pass> \" }"

#Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

#Ensure jq is installed
if [ ! `rpm -qa | grep jq-` ]; then
  yum install jq -y
fi

function getAuth {
  #get API v1 & v2 auth
  getToken=`curl -s "https://${ENDPOINT}/v2/authentication/login" -XPOST -H "Content-Type: application/json" -d "${V2AUTH}"`
  TOKEN=`echo $getToken | jq -r .bearerToken | cut -d \" -f2`

  getV1Cookie=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "cookies.txt" -d "${V1AUTH}"`
}

function getSiteInfo {
  getIndex=`curl -s "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XGET -H "Content-Type: application/json" -u "$ORCH_APIKEY:"`
  checkIndex=`echo $getIndex | jq -r .code`

  if [ "$checkIndex" != "items_not_found" ]; then
    echo $getIndex > ./${SITE_ID}.json
    if [ "${ADD_DC}" == "" ]; then
      DC=`jq -r .Datacenter ./${SITE_ID}.json`
    else
      DC="${ADD_DC}"
    fi
    GET_ENV=`jq -r '.Environments[] | select(.Requested=="True") | .Name' ./${SITE_ID}.json`
    ENV=`echo -n ${GET_ENV} | tr '\n' ','`
    ALOGIC=`jq -r .SecurityTier ./${SITE_ID}.json`
    TECH=`jq -r .TechStack ./${SITE_ID}.json`
    DBAAS=`jq -r .DbaaS ./${SITE_ID}.json`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi
}

function getNetworkList {
  unset destination
  getNetworks=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${1}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
  networkCount=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${1}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"| jq '. | length'`
  for (( k = 0 ; k < ${networkCount} ; k++ )); do
    getGateways=`echo ${getNetworks} | jq '.['${k}'] | .gateway' | sed "s/\"//g"`
    getDestination="`echo ${getGateways} | awk -F. -v OFS='.' '{print $1,$2,$3}'`.0/24"
    setDestination="\"${getDestination}\","
    destination="${setDestination}${destination}"
  done
  #send destinations back to requesting function
  echo ${destination}
}

function checkExisting {
  local ruleCheck="not"
  getRules=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${3}/${DC}?destinationAccount=${4}" -XGET -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json"`
  
  rules=`echo ${getRules} | jq -r '.[] | select(.status!="error") | select(.source[]=="'${1}'") | select(.destination[]=="'${2}'") | .id'`
  if [ "${rules}" != "" ]; then
    ruleCheck="${rules}"
  fi

  echo ${ruleCheck}

}

function createOpenVPNRule {
  local ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json`
  unset existingOvpnID
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi

  getNetworks=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
  webGateway=`echo ${getNetworks} | jq -r '.[] | select(.name=="'${SITE_ID}' - '${1}' - Web") | .gateway'`
  if [ -z ${webGateway} ]; then
    echo "`date +"%c"`: ${1} Web network cannot be found.  Ensure it exists and try again.  Bailing..."
    exit 1
  fi
  setSource="`echo ${webGateway} | awk -F. -v OFS='.' '{print $1,$2,$3}'`.224/27"
  destination=$(getNetworkList ${ACCT})
  getRules_VPN=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}?destinationAccount=${ACCT}" -XGET -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json"`
  rulesCount=`echo "${getRules_VPN}" | jq '. | length'`
  for (( k = 0 ; k < ${rulesCount} ; k++ )); do
    unset existingSourceVPN
    existingSourceVPN=`echo "${getRules_VPN}" | jq '.['${k}'] | .source' | awk -F\" '{print $2}' | sed '/^$/d'`
    if [ "${existingSourceVPN}" == "${setSource}" ]; then
      # Get existing rule and updated it
      existingOvpnID=`echo "${getRules_VPN}" | jq -r '.[] | select(.source[]=="'${existingSourceVPN}'") | .id'`
      break
    fi
  done

  if [ -z ${existingOvpnID} ]; then
    json="{\"destinationAccount\":\"${ACCT}\",\"source\":[\"${setSource}\"],\"destination\":[${destination%?}],\"ports\":[\"tcp/22\",\"tcp/3389\"]}"
    createRule=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${json}"`
    ovpnID=`echo ${createRule} | jq -r '.links[] | .href' | awk -F/ '{print $6}'`
    ovpnStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}/${ovpnID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
    while [ "${ovpnStatus}" == "pending" ]; do
      echo "`date +"%c"`: OpenVPN Firewall Rule Pending for ${1}..."
      sleep 30
      ovpnStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}/${ovpnID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
    done
    if [ "${ovpnStatus}" == "active" ]; then
      echo "`date +"%c"`: OpenVPN Firewall Rule Created for ${1}"
    elif [ "${ovpnStatus}" == "error" ]; then
      echo "`date +"%c"`: OpenVPN Firewall Rule FAILED for ${1}"
    fi
  else
    #Ensure the existing rule has all the required destinations
    countVPNDest="0"
    checkDestinationCount="0"
    countVPNDest=`echo ${destination} | awk -F, '{print NF-1}'`
    checkDestinationCount=`echo ${getRules_VPN} | jq -r '.[] | select(.id=="'${existingOvpnID}'") | .destination | length'`
    if [ ${countVPNDest} -eq ${checkDestinationCount} ]; then
      echo "`date +"%c"`: OpenVPN Firewall Rule already exists for ${1}, Moving on..." 
    else
      updateVPN="{\"enabled\":true,\"source\":[\"${setSource}\"],\"destination\":[${destination%?}],\"ports\":[\"tcp/22\",\"tcp/3389\"]}"
      updateRule=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}/${existingOvpnID}" -XPUT -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${updateVPN}"`
      if [ "${updateRule}" == "" ]; then
        echo "`date +"%c"`: OpenVPN Firewall Rule Updated for ${1}"
      elif [ "${updateRule}" != "" ]; then
        echo "`date +"%c"`: OpenVPN Firewall Rule Update FAILED for ${1}"
      fi
    fi
  fi
}

function parentToSubAccount {
  #Determine Parent subnet
  if [ "${DC}" == "VA1" ]; then
    pSubnet="10.128.138.0/24"
  elif [ "${DC}" == "GB3" ]; then
    pSubnet="10.106.30.0/24"
  elif [ "${DC}" == "UC1" ]; then
    pSubnet="10.122.52.0/24"
  elif [ "${DC}" == "SG1" ]; then
    pSubnet="10.130.82.0/24"
  elif [ "${DC}" == "IL1" ]; then
    pSubnet="10.93.21.0/24"
  else
    echo "No Subnet Found for Parent Account.. Possibly missing datacenter. Bailing..."
    exit 1
  fi
  
  local ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi

  subDestinations=$(getNetworkList ${ACCT})
  countSub=`echo ${subDestinations} | awk -F, '{print NF-1}'`
  countSub=$(( countSub + 1 ))
  for (( d = 1 ; d < ${countSub} ; d++ )); do
    unset checkAny
    oneDestination=`echo ${subDestinations} | awk -F, '{print $'${d}'}'`
    ncOneDestination=`echo ${oneDestination} | awk -F\" '{print $2}' | sed '/^$/d'`
    checkAny=$(checkExisting ${pSubnet} ${ncOneDestination} TCCC ${ACCT})
    if [ "${checkAny}" == "not" ]; then
      # Since no rules exist, we can go ahead and create any and udp
      anyJSON="{\"destinationAccount\":\"${ACCT}\",\"source\":[\"${pSubnet}\"],\"destination\":[${oneDestination}],\"ports\":[\"any\"]}"
      createAnyRule=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${anyJSON}"`
      anyID=`echo ${createAnyRule} | jq -r '.links[] | .href' | awk -F/ '{print $6}' 2> /dev/null`
      if [ "${anyID}" == "" ]; then
        echo "`date +"%c"`: ${ACCT} firewall rules cannot be created, most likely because of a vpn server failure.  An email will be sent to the NOC with the failure.  Once it is resolved please try again."
        cat vpnFailure.txt | sed s/ACCT/${ACCT}/g > ./${ACCT}.txt
        mutt -e "my_hdr From:adaptivesupport@centurylink.com" -s "Failed VPN Server in Alias: ${ACCT}" -c kristen.crawford@centurylink.com support@t3n.zendesk.com adaptivesupport@centurylink.com < ./${ACCT}.txt
        email="yes"
        rm ./${ACCT}.txt
        rm ./${SITE_ID}.json
        exit 1
      else
        anyStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}/${anyID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        while [ "${anyStatus}" == "pending" ]; do
          echo "`date +"%c"`: Parent to SubAccount 'Any' for destination ${ncOneDestination} Firewall Rule Pending for ${1}..."
          sleep 30
          anyStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}/${anyID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        done
        if [ "${anyStatus}" == "active" ]; then
          echo "`date +"%c"`: Parent to SubAccont 'Any' for destination ${ncOneDestination} Firewall Rule Created for ${1}"
        else
          echo "`date +"%c"`: ${ACCT} firewall rules Parent to Subaccount "Any" failed. Verify VPN server has finished deploying and try again!"
	  exit 1
        fi
      fi

      udpJSON="{\"destinationAccount\":\"${ACCT}\",\"source\":[\"${pSubnet}\"],\"destination\":[${oneDestination}],\"ports\":[\"udp/1-65535\"]}"
      createUDPRule=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${udpJSON}"`
      udpID=`echo ${createUDPRule} | jq -r '.links[] | .href' | awk -F/ '{print $6}'`
      udpStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}/${udpID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
      while [ "${udpStatus}" == "pending" ]; do
        echo "`date +"%c"`: Parent to SubAccount 'UDP' for destination ${ncOneDestination} Firewall Rule Pending for ${1}..."
        sleep 30
        udpStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}/${udpID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
      done
      if [ "${udpStatus}" == "active" ]; then
        echo "`date +"%c"`: Parent to SubAccont 'UDP' for destination ${ncOneDestination} Firewall Rule Created for ${1}"
      elif [ "${udpStatus}" == "error" ]; then
        echo "`date +"%c"`: Parent to SubAccont 'UDP' for destination ${ncOneDestination} Firewall Rule FAILED for ${1}"
      fi
    else
      getParentRules=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}?destinationAccount=${ACCT}" -XGET -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json"`
      findAny=`echo ${getParentRules} | jq '.[] | select(.destination[]=="'${ncOneDestination}'") | select(.ports[]=="any")'`
      if [ "${findAny}" != "" ]; then
        echo "`date +"%c"`: Parent to SubAccont 'Any' for destination ${ncOneDestination} already exists for ${ACCT}, moving on.."
      else
        anyJSON="{\"destinationAccount\":\"${ACCT}\",\"source\":[\"${pSubnet}\"],\"destination\":[${oneDestination}],\"ports\":[\"any\"]}"
        createAnyRule=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${anyJSON}"`
        anyID=`echo ${createAnyRule} | jq -r '.links[] | .href' | awk -F/ '{print $6}'`
        anyStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}/${anyID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        while [ "${anyStatus}" == "pending" ]; do
          echo "`date +"%c"`: Parent to SubAccount 'Any' for destination ${ncOneDestination} Firewall Rule Pending for ${1}..."
          sleep 30
          anyStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}/${anyID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        done
        if [ "${anyStatus}" == "active" ]; then
          echo "`date +"%c"`: Parent to SubAccont 'Any' for destination ${ncOneDestination} Firewall Rule Created for ${1}"
        elif [ "${anyStatus}" == "error" ]; then
          echo "`date +"%c"`: Parent to SubAccont 'Any' for destination ${ncOneDestination} Firewall Rule FAILED for ${1}"
        fi 
      fi
      findUDP=`echo ${getParentRules} | jq '.[] | select(.destination[]=="'${ncOneDestination}'") | select(.ports[]=="udp/1-65535")'`
      if [ "${findUDP}" != "" ]; then
        echo "`date +"%c"`: Parent to SubAccont 'UDP' for destination ${ncOneDestination} already exists for ${ACCT}, moving on.."
      else
        udpJSON="{\"destinationAccount\":\"${ACCT}\",\"source\":[\"${pSubnet}\"],\"destination\":[${oneDestination}],\"ports\":[\"udp/1-65535\"]}"
        createUDPRule=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${udpJSON}"`
        udpID=`echo ${createUDPRule} | jq -r '.links[] | .href' | awk -F/ '{print $6}'`
        udpStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}/${udpID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        while [ "${udpStatus}" == "pending" ]; do
          echo "`date +"%c"`: Parent to SubAccount 'UDP' for destination ${ncOneDestination} Firewall Rule Pending for ${1}..."
          sleep 30
          udpStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/TCCC/${DC}/${udpID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        done
        if [ "${udpStatus}" == "active" ]; then
          echo "`date +"%c"`: Parent to SubAccont 'UDP' for destination ${ncOneDestination} Firewall Rule Created for ${1}"
        elif [ "${udpStatus}" == "error" ]; then
          echo "`date +"%c"`: Parent to SubAccont 'UDP' for destination ${ncOneDestination} Firewall Rule FAILED for ${1}"
        fi
      fi
    fi
  done
}

function subAccountToParent {
  #Determine Parent subnet
  if [ "${DC}" == "VA1" ]; then
    pSubnet="10.128.138.0/24"
  elif [ "${DC}" == "GB3" ]; then
    pSubnet="10.106.30.0/24"
  elif [ "${DC}" == "UC1" ]; then
    pSubnet="10.122.52.0/24"
  elif [ "${DC}" == "SG1" ]; then
    pSubnet="10.130.82.0/24"
  elif [ "${DC}" == "IL1" ]; then
    pSubnet="10.93.21.0/24"
  else
    echo "No Subnet Found for Parent Account.. Possibly missing datacenter. Bailing..."
    exit 1
  fi

  local ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi

  subSources=$(getNetworkList ${ACCT})
  count=`echo ${subSources} | awk -F, '{print NF-1}'`
  count=$(( count + 1 ))
  for (( c = 1 ; c < ${count} ; c++ )); do
    unset checkInverse
    oneSource=`echo ${subSources} | awk -F, '{print $'${c}'}'`
    ncOneSource=`echo ${oneSource} | awk -F\" '{print $2}' | sed '/^$/d'`
    checkInverse=$(checkExisting ${ncOneSource} ${pSubnet} ${ACCT} TCCC) 
    if [ "${checkInverse}" == "not" ]; then
      inverseJSON="{\"destinationAccount\":\"TCCC\",\"source\":[${oneSource}],\"destination\":[\"${pSubnet}\"],\"ports\":[\"tcp/1-21\",\"tcp/23-3388\",\"tcp/3390-65535\",\"udp/1-21\",\"udp/22-3388\",\"udp/3390-65535\"]}"
      createInverseRule=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${inverseJSON}"`
      inverseID=`echo ${createInverseRule} | jq -r '.links[] | .href' | awk -F/ '{print $6}'`
      inverseStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}/${inverseID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
      while [ "${inverseStatus}" == "pending" ]; do
        echo "`date +"%c"`: SubAccount Source $ncOneSource to Parent Firewall rule status: ${inverseStatus}"
        sleep 30
        inverseStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}/${inverseID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
      done
      if [ "${inverseStatus}" == "active" ]; then
        echo "`date +"%c"`: SubAccount Source $ncOneSource to Parent Firewall Rule Created for ${1}"
      elif [ "${inverseStatus}" == "error" ]; then
        echo "`date +"%c"`: SubAccount Source $ncOneSource to Parent Firewall Rule FAILED for ${1}"
      fi
   else
     echo "`date +"%c"`: SubAccount Source ${ncOneSource} to Parent Firewall Rule already exists for ${1}, Moving on..."
    fi
  done

}

function webToDbRule {
  local ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi

  getNetworks=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
  networkCount=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"| jq '. | length'`
  for (( i = 0 ; i < ${networkCount} ; i++ )); do
    getName=`echo ${getNetworks} | jq -r '.['${i}'] | .name'`
    if [ "${getName}" == "${SITE_ID} - ${1} - Web" ]; then
      getSourceGateway=`echo ${getNetworks} | jq -r '.['${i}'] | .gateway'`
      setSource="`echo ${getSourceGateway} | awk -F. -v OFS='.' '{print $1,$2,$3}'`.0/24"
    fi
    if [ "${getName}" == "${SITE_ID} - ${1} - DB" ]; then
      getDestGateway=`echo ${getNetworks} | jq -r '.['${i}'] | .gateway'`  
      setDestination="`echo ${getDestGateway} | awk -F. -v OFS='.' '{print $1,$2,$3}'`.0/24"
    fi
  done

  if [[ "${TECH}" == "Lamp" || "${TECH}" == "Java" ]]; then
    webToDbJSON="{\"destinationAccount\":\"${ACCT}\",\"source\":[\"${setSource}\"],\"destination\":[\"${setDestination}\"],\"ports\":[\"tcp/22\",\"tcp/3389\",\"tcp/3306\"]}"
  elif [[ "${TECH}" == "IIS" || "${TECH}" == "WIM" ]]; then
    webToDbJSON="{\"destinationAccount\":\"${ACCT}\",\"source\":[\"${setSource}\"],\"destination\":[\"${setDestination}\"],\"ports\":[\"tcp/22\",\"tcp/3389\",\"tcp/1433\"]}"
  else
    echo "Tech Stack not found, bailing..." 
    exit 1
  fi
  check=$(checkExisting ${setSource} ${setDestination} ${ACCT} ${ACCT})
  if [ "${check}" == "not" ]; then
    createWebToDbRule=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${webToDbJSON}"`
    ruleID=`echo ${createWebToDbRule} | jq -r '.links[] | .href' | awk -F/ '{print $6}'`
    createRuleStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}/${ruleID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
    while [ "${createRuleStatus}" == "pending" ]; do
      echo "`date +"%c"`: Web to DB Firewall Rule Pending for ${1}..."
      sleep 30
      createRuleStatus=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}/${ruleID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
    done
    if [ "${createRuleStatus}" == "active" ]; then
      echo "`date +"%c"`: Web to DB Firewall Rule Created for ${1}"
    elif [ "${createRuleStatus}" == "error" ]; then
      echo "`date +"%c"`: Web to DB Firewall Rule FAILED for ${1}"
    fi
  else
    echo "`date +"%c"`: Web to DB Firewall Rule already exists for ${1}. Moving on..."
  fi

}

function xDcRules {
  local ACCT=`jq -r '.Environments[] | select(.Name=="'${1}'") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi

  lowerACCT=`echo ${ACCT} | awk '{print tolower($0)}'`

  va1Source="10.128.138.0/24"
  uc1Source="10.122.52.0/24"
  
  getNetworks=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
  networkCount=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"| jq '. | length'`
  for (( z = 0 ; z < ${networkCount} ; z++ )); do
    getDestGateway=`echo ${getNetworks} | jq -r '.['${z}'] | .gateway'`
    setDestination="`echo ${getDestGateway} | awk -F. -v OFS='.' '{print $1,$2,$3}'`.0/24"
    getXDCRules=`curl -s "https://${ENDPOINT}/v2-experimental/crossDcFirewallPolicies/TCCC/VA1?destinationAccountId=${ACCT}" -XGET -H "Authorization: Bearer ${TOKEN}"`
    if [ "${DC}" != "VA1" ]; then
      va1ID=`echo ${getXDCRules} | jq -r '.[] | select(.status!="error") | select(.sourceCidr=="'${va1Source}'") | select(.destinationCidr=="'${setDestination}'") | .id'`
      if [ "${va1ID}" == "" ]; then
        va1XDCJSON="{\"destinationAccountId\":\"${ACCT}\",\"destinationLocationId\":\"${DC}\",\"destinationCidr\":\"${setDestination}\",\"enabled\":true,\"sourceCidr\":\"${va1Source}\"}"
        createXDCtoVA1=`curl -s "https://${ENDPOINT}/v2-experimental/crossDcFirewallPolicies/TCCC/VA1" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${va1XDCJSON}"`
        xdcVA1Rule=`echo ${createXDCtoVA1} | jq -r '.links[] | .href'`
        xDCRuleStatus=`curl -s "https://${ENDPOINT}/${xdcVA1Rule}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        while [ "${xDCRuleStatus}" == "pending" ]; do
          echo "`date +"%c"`: VA1 TCCC -> ${ACCT} Firewall Rule Pending for ${1}..."
          sleep 30
          xDCRuleStatus=`curl -s "https://${ENDPOINT}/${xdcVA1Rule}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        done
        if [ "${xDCRuleStatus}" == "active" ]; then
          echo "`date +"%c"`: VA1 TCCC -> ${ACCT} Firewall Rule Created for ${1}"
        elif [ "${xDCRuleStatus}" == "error" ]; then
          echo "`date +"%c"`: VA1 TCCC -> ${ACCT} Firewall Rule FAILED for ${1}"
        fi
      else
        echo "`date +"%c"`: Cross Datacenter Firewall Rule already exists for VA1 TCCC -> ${ACCT}. Moving on..."
      fi
    fi

    if [ "${DC}" != "UC1" ]; then
      getUC1XDCRules=`curl -s "https://${ENDPOINT}/v2-experimental/crossDcFirewallPolicies/TCCC/UC1?destinationAccountId=${ACCT}" -XGET -H "Authorization: Bearer ${TOKEN}"`
      uc1ID=`echo ${getUC1XDCRules} | jq -r '.[] | select(.status!="error") | select(.sourceCidr=="'${uc1Source}'") | select(.destinationCidr=="'${setDestination}'") | .id'`
      if [ "${uc1ID}" == "" ]; then
        uc1XDCJSON="{\"destinationAccountId\":\"${ACCT}\",\"destinationLocationId\":\"${DC}\",\"destinationCidr\":\"${setDestination}\",\"enabled\":true,\"sourceCidr\":\"${uc1Source}\"}"
        createXDCtoUC1=`curl -s "https://${ENDPOINT}/v2-experimental/crossDcFirewallPolicies/TCCC/UC1" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${uc1XDCJSON}"`
        xdcUC1Rule=`echo ${createXDCtoUC1} | jq -r '.links[] | .href'`
        xDCUC1RuleStatus=`curl -s "https://${ENDPOINT}/${xdcUC1Rule}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        while [ "${xDCUC1RuleStatus}" == "pending" ]; do
          echo "`date +"%c"`: UC1 TCCC -> ${ACCT} Firewall Rule Pending for ${1}..."
          sleep 30
          xDCUC1RuleStatus=`curl -s "https://${ENDPOINT}/${xdcUC1Rule}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
        done
        if [ "${xDCUC1RuleStatus}" == "active" ]; then
          echo "`date +"%c"`: UC1 TCCC -> ${ACCT} Firewall Rule Created for ${1}"
        elif [ "${xDCUC1RuleStatus}" == "error" ]; then
          echo "`date +"%c"`: UC1 TCCC -> ${ACCT} Firewall Rule FAILED for ${1}"
        fi
      else
        echo "`date +"%c"`: Cross Datacenter Firewall Rule already exists for UC1 TCCC -> ${ACCT}. Moving on..."
      fi
    fi
  done
}

function webToDMZRule {
  local ACCT=`jq -r '.Environments[] | select(.Name=="Production") | .Alias' ./${SITE_ID}.json`
  if [ ${ACCT} == "null" ]; then
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  fi

  networks=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}"`
  webCidr=`echo ${networks} | jq -r '.[] | select (.name=="'${SITE_ID}' - Production - Web") | .cidr'`
  dmzCidr=`echo ${networks} | jq -r '.[] | select (.name=="'${SITE_ID}' - Production - DMZ") | .cidr'`
  checkDMZ=$(checkExisting ${dmzCidr} ${webCidr} ${ACCT} ${ACCT})
  checkWeb=$(checkExisting ${webCidr} ${dmzCidr} ${ACCT} ${ACCT})
  if [ "${checkDMZ}" == "not" ]; then
    dmzRuleJSON="{\"destinationAccount\":\"${ACCT}\",\"source\":[\"${dmzCidr}\"],\"destination\":[\"${webCidr}\"],\"ports\":[\"tcp/80\",\"tcp/443\"]}"
    createDMZtoWebRule=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${dmzRuleJSON}"`
    dmzID=`echo ${createDMZtoWebRule} | jq -r '.links[] | .href'`
    createDMZStatus=`curl -s "https://${ENDPOINT}/${dmzID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
    echo "${createDMZStatus}"
    while [ "${createDMZStatus}" == "pending" ]; do
      echo "`date +"%c"`: DMZ to Web Firewall Rule Pending..."
      sleep 30
      createDMZStatus=`curl -s "https://${ENDPOINT}/${dmzID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
    done
    if [ "${createDMZStatus}" == "active" ]; then
      echo "`date +"%c"`: DMZ to Web Firewall Rule Created in Production" 
    elif [ "${createDMZStatus}" == "error" ]; then
      echo "`date +"%c"`: DMZ to Web Firewall Rule FAILED in Production.."
      exit 1
    fi
  else
    echo "`date +"%c"`: DMZ to Web Firewall Rule already exists in Production. Moving on..."
  fi
  if [ "${checkWeb}" == "not" ]; then
    webRuleJSON="{\"destinationAccount\":\"${ACCT}\",\"source\":[\"${webCidr}\"],\"destination\":[\"${dmzCidr}\"],\"ports\":[\"tcp/80\",\"tcp/443\"]}"
    createWebtoDMZRule=`curl -s "https://${ENDPOINT}/v2-experimental/firewallPolicies/${ACCT}/${DC}" -XPOST -H "Authorization: Bearer ${TOKEN}" -H "Content-Type: application/json" -d "${webRuleJSON}"`
    webID=`echo ${createWebtoDMZRule} | jq -r '.links[] | .href'`
    createWebStatus=`curl -s "https://${ENDPOINT}/${webID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
    while [ "${createWebStatus}" == "pending" ]; do
      echo "`date +"%c"`: Web to DMZ Firewall Rule Pending..."
      sleep 30
      createWebStatus=`curl -s "https://${ENDPOINT}/${webID}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq -r .status`
    done
    if [ "${createWebStatus}" == "active" ]; then
      echo "`date +"%c"`: Web to DMZ Firewall Rule Created in Production"
    elif [ "${createDMZStatus}" == "error" ]; then
      echo "`date +"%c"`: Web to DMZ Firewall Rule FAILED in Production.."
      exit 1
    fi
  else
    echo "`date +"%c"`: Web to DMZ Firewall Rule already exists in Production. Moving on..."
  fi

}

getAuth;
getSiteInfo;

# Create firewall rules per environment
NUMENV=`echo $ENV | awk -F "," '{print NF-1}'`
NUMENV=$(( NUMENV + 1 ))
for (( j = 1 ; j <= ${NUMENV} ; j++ )); do
  unset currentEnv
  currentEnv=`echo $ENV | awk -F "," '{print $'$j'}'`
  parentToSubAccount "${currentEnv}"
  subAccountToParent "${currentEnv}"
  if [ "${DBAAS}" == "false" ]; then
    webToDbRule "${currentEnv}"
  fi
  createOpenVPNRule "${currentEnv}"
  xDcRules "${currentEnv}"
  if [ "${currentEnv}" == "Production" ]; then
    if [[ ${ALOGIC} -eq 1 || ${ALOGIC} -eq 2 ]]; then
      webToDMZRule;
    fi
  fi
done

# cleanup
rm ./${SITE_ID}.json
