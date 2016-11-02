## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ENV="${2}"
ADD_DC="${3}"
if [ "${ADD_DC}" == "" ]; then
  DC=`jq -r .Datacenter ./${SITE_ID}.json`
else
  DC="${ADD_DC}"
fi

ACCT=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Alias' ./${SITE_ID}.json`
if [ ${ACCT} == "null" ]; then
  ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
fi

REF_ARCH=`jq -r .ReferenceArchitecture ./${SITE_ID}.json`
pw=`mkpasswd -l 20 -d 3 -C 5 -s 0`

#Control Information
ENDPOINT="api.ctl.io"
V2AUTH="{ \"username\": \" <v2 user> \", \"password\": \" <v2 pass> \" }"
V1AUTH="{ \"APIKey\": \" <v1 key> \", \"Password\": \" <v1 pass> \" }"

function getAuth {
  #get API v1 & v2 auth
  getToken=`curl -s "https://${ENDPOINT}/v2/authentication/login" -XPOST -H "Content-Type: application/json" -d "${V2AUTH}"`
  TOKEN=`echo $getToken | jq -r .bearerToken | cut -d \" -f2`

  getV1Cookie=`curl -s "https://${ENDPOINT}/REST/Auth/Logon" -XPOST -H "Content-type: application/json" -c "cookies.txt" -d "${V1AUTH}"`
}

function createSubscription {
  if [ "${REF_ARCH}" == "Basic" ]; then
    instType="MySQL"
  elif [ "${REF_ARCH}" == "Standard" ]; then
    instType="MySQL_REPLICATION"
  else
    echo "No reference architecture found.. this shouldn't have happened! Bailing.."
    exit 1
  fi

  if [ "${ENV}" == "Test" ]; then
    days="15"
    S_ENV="TST"
    instType="MySQL"
  elif [ "${ENV}" == "Production" ]; then
    days="31"
    S_ENV="PRD"
  else
    echo "No environment found.. This shouldn't have happened! Bailing.."
  fi

  rdbsJSON="{\"instanceType\":\"${instType}\",\"location\":\"${DC}\",\"externalId\":\"KO${SITE_ID}RDB${S_ENV}\",\"machineConfig\":{\"cpu\":1,\"memory\":2,\"storage\":5},\"backupRetentionDays\": ${days},\"users\":[{\"name\":\"admin\",\"password\":\"${pw}\"}],\"backupTime\":{\"hour\":0,\"minute\":15}}"
  createSubscription=`curl -s --tlsv1.1 "https://api.rdbs.ctl.io:443/v1/${ACCT}/subscriptions" -XPUT -H "Authorization: Bearer ${TOKEN}" -XPOST --header "Content-Type: application/json" --header "Accept: application/json" -d "${rdbsJSON}"`

  checkBuild=`echo ${createSubscription} | jq '.id' 2> /dev/null`
  if [ "${checkBuild}" != "" ]; then
    echo "`date +"%c"`: Relational Database for ${ACCT} has been successfully configured."
    prettyOutput=`echo ${createSubscription} | jq .`
    echo "${prettyOutput}" >> ./${SITE_ID}-${ENV}-dbinfo.json
    curl -sk --form uploaded_file=@./${SITE_ID}-${ENV}-dbinfo.json --form submit=SUBMIT https://dropbox.ko.cld/ws/accept-file.php -o /dev/null
    if [ "$?" == "0" ]; then
      echo "`date +"%c"`: ${SITE_ID}-${ENV}-dbinfo.json successfully transfered to the dropbox.ko.cld and will be available in less than 10 minutes."
      rm ./${SITE_ID}-${ENV}-dbinfo.json
    else
      echo "`date +"%c"`: ${SITE_ID}-${ENV}-dbinfo.json transfer to dropbox failed, please send it manually"
    fi
  else
    echo "`date +"%c"`: Create Relational Database Subscription has failed!  Review the logs for errors and try again. Moving on..."
  fi
}

getAuth;
checkActive=`curl -s --tlsv1.1 "https://api.rdbs.ctl.io:443/v1/${ACCT}/subscriptions?dataCenter=${DC}&status=ACTIVE" -XGET -H "Authorization: Bearer ${TOKEN}" --header "Accept: application/json" | jq .`
checkConfiguring=`curl -s --tlsv1.1 "https://api.rdbs.ctl.io:443/v1/${ACCT}/subscriptions?dataCenter=${DC}&status=CONFIGURING" -XGET -H "Authorization: Bearer ${TOKEN}" --header "Accept: application/json" | jq .`
if [[ "${checkActive}" == "[]" && "${checkConfiguring}" == "[]" ]]; then
  createSubscription;
else
  echo "`date +"%c"`: Relational Database for ${ACCT} has already been setup. Moving on..."
fi
