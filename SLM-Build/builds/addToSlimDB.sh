## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
SERVER="${2}"
ENV="${3}"
HOST_IP="${4}"
updateVer=""
# Verify who is running the script so you know which db to use.  Root writes to Test and udeploy writes to Prod (through udeploy)
user=`whoami`
if [ "${user}" == "root" ]; then
  db="Test"
elif [ "${user}" == "siterun" ]; then
  db="Prod"
else
  echo "`date +"%c"`: ${user} is not authorized to update slimdb! Please use udeploy user (via udeploy)"
fi

#Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

function setVars {
  if [[ "${SERVER}" =~ "WEB" ]]; then
    OS="Red Hat Enterprise Linux 6 (64-bit)"
    hostType="web"
    updateVer="SET apacheVer='2.2.25',phpVer='5.4.19'"
  elif [[ "${SERVER}" =~ "WA" ]]; then
    OS="Red Hat Enterprise Linux 6 (64-bit)"
    hostType="app"
    updateVer="SET apacheVer='2.2.25',tomcatVer='7.0.42'"
  elif [[ "${SERVER}" =~ "MYSQL" ]]; then
    OS="Red Hat Enterprise Linux 6 (64-bit)"
    hostType="data"
    updateVer="SET dbVer='5.6'"
  elif [[ "${SERVER}" =~ "IIS" ]]; then
    OS="Windows 2012R2 Datacenter (64-bit)"
    hostType="web"
    updateVer="SET iisVer='8.5.9'"
  elif [[ "${SERVER}" =~ "MSSQL" ]]; then
    OS="Windows 2012R2 Datacenter (64-bit)"
    hostType="data"
    updateVer="SET dbVer='12.0.4'"
  elif [[ "${SERVER}" =~ "FS" ]]; then
    OS="Red Hat Enterprise Linux 6 (64-bit)"
    hostType="file"
  elif [[ "${SERVER}" =~ "MCHE" ]]; then
    OS="Red Hat Enterprise Linux 6 (64-bit)"
    hostType="memd"
  elif [[ "${SERVER}" =~ "ALOGIC" ]]; then
    OS="Red Hat Enterprise Linux 6 (64-bit)"
    hostType="waf"
  else
    echo "`date +"%c"`: Server Type not Found! Manually enter ${SERVER} to the slimdb. Moving on..."
    exit 1
  fi
  if [ "${ENV}" == "Test" ]; then
    ENV_ID="${SITE_ID}-01"
  elif [ "${ENV}" == "Production" ]; then
    ENV_ID="${SITE_ID}-00"
  else
    echo "`date +"%c"`: No Environment sent! Moving on..."
    exit 1
  fi
}

function updateSlimDB {
  serverCheck=`mysql -e "SELECT hostname FROM SLIMDB_${db}.siteConfigData WHERE hostname='${SERVER}';" | grep -v hostname`
  if [ "${serverCheck}" == "${SERVER}" ]; then
    echo "`date +"%c"`: ${SERVER} has already been added to Slim DB. Moving on .."
  else
    insertServer=`mysql -e "INSERT INTO SLIMDB_${db}.siteConfigData (siteId,hostname,hostIp,cpuCount,mem,storage,os,hostStatus,hostType) VALUES('${ENV_ID}','${SERVER}','${HOST_IP}','1','2','13312','${OS}','running','${hostType}')" 2>&1`
    if [ "${insertServer}" == "" ]; then
      echo "`date +"%c"`: New Server ${SERVER} has been added to the SLIM Database for ${SITE_ID}"

      if [ "${updateVer}" != "" ]; then
        updateServerVers=`mysql -e "UPDATE SLIMDB_${db}.siteConfigData ${updateVer} WHERE hostname='${SERVER}';" 2>&1` 
        if [ "${updateServerVers}" != "" ]; then
	  echo "`date +"%c"`: Software Versions for  Server ${SERVER} could not be added. Remember to add them manually!"
        fi
      fi
    else
      echo "`date +"%c"`: New Server ${SERVER} was not added to the slim db. Error: ${insertServer}"
    fi
  fi
}

## Main
setVars;
updateSlimDB;
