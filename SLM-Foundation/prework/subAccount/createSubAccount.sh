#!/bin/bash

#
#      _____            _                    _     _       _      _____ _                 _
#     /  __ \          | |                  | |   (_)     | |    /  __ \ |               | |
#     | /  \/ ___ _ __ | |_ _   _ _ __ _   _| |    _ _ __ | | __ | /  \/ | ___  _   _  __| |
#     | |    / _ \ '_ \| __| | | | '__| | | | |   | | '_ \| |/ / | |   | |/ _ \| | | |/ _` |
#     | \__/\  __/ | | | |_| |_| | |  | |_| | |___| | | | |   <  | \__/\ | (_) | |_| | (_| |
#      \____/\___|_| |_|\__|\__,_|_|   \__, \_____/_|_| |_|_|\_\  \____/_|\___/ \__,_|\__,_|
#                                        __/ |
#                                       |___/
#
#
## Set variables configured in package.manifest
SITE_ID="${1}"
NEW_DC="${2}"

#Control Information
ENDPOINT="api.ctl.io"
V2AUTH="{ \"username\": \" <v2 user> \", \"password\": \" <v2 pass> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 pass> \" }"
ACCT_V1AUTH="{ \"APIKey\": \"${API_KEY}\", \"Password\": \"${API_PSSWD}\" }"

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
    PARENTALIAS=`jq -r .CLCParentAlias ./${SITE_ID}.json`
    ACCOUNTALIAS=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
    TESTALIAS=`echo ${ACCOUNTALIAS} | sed s/K/T/g`
    PRODALIAS=`echo ${ACCOUNTALIAS} | sed s/K/P/g`
    DEVALIAS=`echo ${ACCOUNTALIAS} | sed s/K/D/g`
    ACCOUNTNAME=`jq -r .ApplicationName ./${SITE_ID}.json`
    DC=`jq -r .Datacenter ./${SITE_ID}.json`
    GET_ENV=`jq -r '.Environments[] | select(.Requested=="True") | .Name' ./${SITE_ID}.json`
    ENV=`echo -n "$GET_ENV"|tr '\n' ','`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi
}

function createSubAccount {
  if [ ${1} != ${PARENTALIAS} ]; then
    if [ ${2} == "Production" ]; then
      ACCOUNTALIAS="${PRODALIAS}"
    elif [ ${2} == "Test" ]; then
      ACCOUNTALIAS="${TESTALIAS}"
    elif [ ${2} == "Dev" ]; then
      ACCOUNTALIAS="${DEVALIAS}"
    fi
  fi
  ## Verify if an account already exists, if not create
  getAccount=`curl -s "https://${ENDPOINT}/REST/Account/GetAccountDetails/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${ACCOUNTALIAS}\"}"`
  accountStatus=`echo ${getAccount} | jq -r .StatusCode`
  if [ ${accountStatus} -eq 5 ]; then
    NewAccountJSON="{\"ParentAlias\": \"${1}\",\"AccountAlias\":\"${ACCOUNTALIAS}\",\"Location\": \"${DC}\",\"BusinessName\": \"${SITE_ID} - ${2}\",\"Address1\": \"1 Coca-Cola Plz\",\"Address2\": null,\"City\": \"Atlanta\",\"StateProvince\": \"GA\",\"PostalCode\": \"30301\",\"Country\": \"USA\",\"Telephone\": \"888-606-6776\",\"Fax\": null,\"TimeZone\":\"US Eastern Standard Time\",\"ShareParentNetworks\": \"False\",\"BillingResponsibilityID\": \"2\"}"

    createAccount=`curl -s "https://${ENDPOINT}/REST/Account/CreateAccount/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "${NewAccountJSON}"`
    echo "${createAccount}"
    createStatus=`echo ${createAccount} | jq -r .Success`
    if [ "${createStatus}" == "true" ]; then
      echo "`date +"%c"`: Account Alias ${ACCOUNTALIAS} has been created successfully"

      # Add the alias for env sub accounts to the site json
      if [[ ${ACCOUNTALIAS} != K* ]]; then
        updateSiteJSON ${2} ${ACCOUNTALIAS}
        createTrashServer ${ACCOUNTALIAS};
      fi  
    else
      echo "`date +"%c"`: Account was not created, Bailing!!"
      exit 1
    fi
  elif [ ${accountStatus} -eq 0 ]; then
    echo "`date +"%c"`: Account Alias ${ACCOUNTALIAS} already exists, moving on.."
  else
    echo "`date +"%c"`: Get Account Status failed with error ${accountStatus}.  See API docs for more info... Bailing!!"
  exit 1
fi
}

function createTrashServer {
  getAuth;
  ttl=`date +%FT%TZ -d "+1 days"`
  getGroups=`curl -s "https://${ENDPOINT}/REST/Group/GetGroups/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "{\"AccountAlias\":\"${1}\",\"Location\":\"${DC}\"}"`
  parentGroup=`echo ${getGroups} | jq '.HardwareGroups[] | select(.Name=="Default Group") | .UUID' | sed "s/\"//g"`
  serverJSON="{\"name\": \"Trash\",\"groupId\":\"${parentGroup}\",\"sourceServerId\":\"RHEL-7-64-TEMPLATE\",\"password\":\"svvs123!!\",\"cpu\":2,\"memoryGB\":4,\"type\":\"standard\",\"storageType\":\"standard\",\"ttl\":\"${ttl}\"}"
  trashServer=`curl -s "https://${ENDPOINT}/v2/servers/${1}" -XPOST -H "Authorization: Bearer ${TOKEN}" -XPOST -H "Content-type: application/json" -d "${serverJSON}"` 
  echo "${trashServer}"
  trashID=`echo ${trashServer} | jq -r '.links[] | select (.rel=="status") | .href'`
  trashStatus=`curl -s "https://${ENDPOINT}/${trashID}" -XPOST -H "Authorization: Bearer ${TOKEN}" -XGET -H "Content-type: application/json" | jq -r .status`
  echo "`date +"%c"`: Trash Server status for ${1}: ${trashStatus}"
  timer="0"
  until [ ${trashStatus} == "succeeded" ]; do
    sleep 30
    trashStatus=`curl -s "https://${ENDPOINT}/${trashID}" -XPOST -H "Authorization: Bearer ${TOKEN}" -XGET -H "Content-type: application/json" | jq -r .status`
    echo "`date +"%c"`: Trash Server status for ${1}: ${trashStatus}"
    timer=$(( timer + 1 ))
    if [ ${timer} == 15 ]; then
      break
    fi
  done

  if [ "${trashStatus}" == "succeeded" ]; then
    echo "`date +"%c"`: The trash server for ${1} has been created"
  else
    echo "`date +"%c"`: Trash server was not created, Bailing!!"
    exit 1
  fi

}

function updateSiteJSON {
  updateAlias=`jq '(.Environments[] | select(.Name=="'${1}'")) |= .+ {"Alias": "'${2}'"}' ./${SITE_ID}.json`
  rm -rf ./${SITE_ID}.json
  echo ${updateAlias} > ./${SITE_ID}.json
  echo "`date +"%c"`: ${SITE_ID}.json updated with account alias: ${ACCOUNTALIAS}"
  updateOrchestrate;
}

function addDatacenter {
  dateAdded=`date +%Y-%m-%d`
  jsonCheck=`cat 996633.json | grep 'AdditionalDatacenters'`
  if [ "${jsonCheck}" == "" ]; then
    addArray=`jq '(. |= .+ {"AdditionalDatacenters": []})' ./${SITE_ID}.json`
    rm -rf ./${SITE_ID}.json
    echo ${addArray} > ./${SITE_ID}.json
  fi
  filter="jq '.AdditionalDatacenters[] | select(.Location==\"${NEW_DC}\")'"
  dc_found=$(eval ${filter} ./${SITE_ID}.json)
  if [ -z "${dc_found}" ]; then
    total=`jq '.AdditionalDatacenters[] | length' ./${SITE_ID}.json | wc -l`
    putDC=`jq '.AdditionalDatacenters['${total}'] |= .+ { "Location": "'${NEW_DC}'", "DateAdded": "'${dateAdded}'" }' ./${SITE_ID}.json`
    rm -rf ./${SITE_ID}.json
    echo ${putDC} > ./${SITE_ID}.json
    echo "`date +"%c"`: ${SITE_ID}.json updated with additional datacenter: ${NEW_DC}"
    updateOrchestrate;
  else
    echo "`date +"%c"`: Additional Datacenter: ${NEW_DC} has already been added to ${SITE_ID}.json"
  fi
}

function updateOrchestrate {
  JSON=`cat ./${SITE_ID}.json`
  curl -is "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XPUT -H "Content-Type: application/json" -u "${ORCH_APIKEY}:" -d "${JSON}" -o /dev/null
}

## Do the things
getAuth;
getSiteInfo;
#updateOrchestrate;
#exit

#If all we weant to do is add a datacenter we can update the json and then exist
if [ "${NEW_DC}" != "" ]; then
  addDatacenter;
  exit 0
fi

createSubAccount "${PARENTALIAS}" "${ACCOUNTNAME}";
getParentNetCount=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCOUNTALIAS}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq '. | length'`
if [ ${getParentNetCount} -eq 0 ]; then
  createTrashServer ${ACCOUNTALIAS};
fi

NUMENV=`echo $ENV | awk -F "," '{print NF-1}'`
NUMENV=$(( NUMENV + 1 ))
for (( j = 1 ; j <= ${NUMENV} ; j++ )); do
  unset currentEnv
  unset ACCOUNTALIAS
  currentEnv=`echo $ENV | awk -F "," '{print $'$j'}'`
  ACCOUNTALIAS=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
  createSubAccount ${ACCOUNTALIAS} ${currentEnv}
  if [ "${currentEnv}" == "Production" ]; then
    ACCT="${PRODALIAS}"
  elif [ ${currentEnv} == "Test" ]; then
    ACCT="${TESTALIAS}"
  elif [ ${currentEnv} == "Dev" ]; then
    ACCT="${DEVALIAS}"
  fi
  # check network count in site account, only if it is 0 then make a trash server
  getSubNetworkCount=`curl -s "https://${ENDPOINT}/v2-experimental/networks/${ACCT}/${DC}" -XGET -H "Authorization: Bearer ${TOKEN}" | jq '. | length'`
  if [ ${getSubNetworkCount} -eq 0 ]; then
    createTrashServer ${ACCT};
  fi
done


# cleanup
rm ./${SITE_ID}.json
