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
#    middleware.sh
#    Kristen Crawford <kristen.crawford@centurylink.com>
#
#    Run provisionCLCSite.py
#    Run create hieradata for each server
#    Run siteSvnCreate
#    Update Puppet Master
#
#### Changelog
#
##   2016.01.22 <kristen.crawford@centurylink.com>
## - Initial release
#
## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"
ENV="${2}"
ADD_DC="${3}"
runPupdate="false"
runScupdate="false"

#NOTE# Orchestrate.io Information
ORCH_APIKEY=""
ORCH_ENDPOINT=""
COLLECTION=""

#Ensure jq is installed
if [ ! `rpm -qa | grep jq-` ]; then
  yum install jq -y
fi

function getSiteInfo {
  getIndex=`curl -s "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XGET -H "Content-Type: application/json" -u "$ORCH_APIKEY:"`
  checkIndex=`echo $getIndex | jq -r .code`

  if [ "$checkIndex" != "items_not_found" ]; then
    echo $getIndex > ./${SITE_ID}.json
    STACK=`jq -r .TechStack ./${SITE_ID}.json`
    SHIB=`jq -r .Shibboleth ./${SITE_ID}.json`
    if [ "${ADD_DC}" == "" ]; then
      DC=`jq -r .Datacenter ./${SITE_ID}.json`
    else
      DC="${ADD_DC}"
    fi
    puppetMaster="pup-master.${DC}.ko.cld"
    DBAAS=`jq -r .DbaaS ./${SITE_ID}.json`
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi

}

function updateOrchestrate {
  JSON=`cat ./${SITE_ID}.json`
  curl -is "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XPUT -H "Content-Type: application/json" -u "${ORCH_APIKEY}:" -d "${JSON}" -o /dev/null
}

function provisionSite {
  switch='-u automation -i '${SITE_ID}' -e'
  provisionCheck=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Provisioned' ./${SITE_ID}.json`
  if [ "${provisionCheck}" != "Completed" ]; then
    if [ "${ENV}" == "Production" ]; then
       lowerEnv="prod"
    elif [ "${ENV}" == "Test" ]; then
       lowerEnv="test"
    elif [ "${ENV}" == "Dev" ]; then
       lowerEnv="dev"
    fi
    switch=''${switch}' '${lowerEnv}':11.11.11.11'

    if [ "${STACK}" == "Lamp" ]; then
      if [ "${DBAAS}" == "true" ]; then
        switch=''${switch}' --httpd --php'
      else
        switch=''${switch}' --httpd --php --mysql'
      fi
    elif [ "${STACK}" == "Java" ]; then
      if [ "${DBAAS}" == "true" ]; then
        switch=''${switch}' --httpd --tomcat'
      else
        switch=''${switch}' --httpd --tomcat --mysql'
      fi
    elif [ "${STACK}" == "Jamp" ]; then
      if [ "${DBAAS}" == "true" ]; then
        switch=''${switch}' --httpd --tomcat --php'
      else
        switch=''${switch}' --httpd --tomcat --mysql --php'
      fi
    else
      echo "Tech Stack not specified! Bailing..."
      exit 1
    fi

    if [[ "${SHIB}" == "true" || "${SHIB}" == "True" ]]; then
      switch=''${switch}' --shib'
    fi

    provision=`eval /usr/bin/python /opt/ko/scripts/lms/provisionCLCSite.py ${switch}`
    if [ "${?}" == "0" ]; then
      echo "Provision CLC site is complete for ${SITE_ID} ${ENV}"
      runScupdate="true"
      # Mark environment provisioned as completed in site json
      updateProvision=`jq '(.Environments[] | select(.Name=="'${ENV}'")) |= .+ {"Provisioned": "Completed"}' ./${SITE_ID}.json`
      rm -rf ./${SITE_ID}.json
      echo ${updateProvision} > ./${SITE_ID}.json
    else
      echo ${provision}
    fi
  else
    echo "${SITE_ID} ${ENV} is already provisioned. Moving on..."
  fi
}

function provisionSecondSite {
  #Setup env dirs
  if [ "${ENV}" == "Production" ]; then
     lowerEnv="prod"
  elif [ "${ENV}" == "Test" ]; then
     lowerEnv="test"
  elif [ "${ENV}" == "Dev" ]; then
     lowerEnv="dev"
  fi
  #Setup Destination
  if [ "${DC}" == "VA1" ]; then
    dest="VA1TCCCLMS0102.va1.savvis.net"
  else
    dest="${DC}TCCCLMS01.${DC}.savvis.net"
  fi

  #Figure out source and set it
  srcDC=`jq -r .Datacenter ./${SITE_ID}.json`
  if [ "${srcDC}" == "VA1" ]; then
    src="VA1TCCCLMS0102.va1.savvis.net"
  else
    src="${srcDC}TCCCLMS01.${srcDC}.savvis.net"
  fi

  #Get existing versions
  srcConfig="/opt/ko/site-configs/${SITE_ID}/provisioned.yaml"
  origYAML=`ssh ${src} "cat ${srcConfig}"`

  ## Get version will look something like this if site is lamp
  origPHP=`echo "${origYAML}" | grep php | awk '{print $2}' | awk -F. '{print $1$2}'`
  origHTTP=`echo "${origYAML}" | grep httpd | awk '{print $2}' | awk -F. '{print $1$2}'`
  origTOM=`echo "${origYAML}" | grep tomcat | awk '{print $2}' | awk -F. '{print $1}'`

  switch='-u automation -i '${SITE_ID}' -e'
  provisionCheck=`jq -r '.AdditionalDatacenters[] | select(.Location=="'${DC}'") | .'${ENV}'' ./${SITE_ID}.json`
  if [ "${provisionCheck}" != "Provisioned" ]; then
    if [ "${ENV}" == "Production" ]; then
       lowerEnv="prod"
    elif [ "${ENV}" == "Test" ]; then
       lowerEnv="test"
    elif [ "${ENV}" == "Dev" ]; then
       lowerEnv="dev"
    fi
    switch=''${switch}' '${lowerEnv}':11.11.11.11'

    if [ "${STACK}" == "Lamp" ]; then
      if [ "${DBAAS}" == "true" ]; then
        switch=''${switch}' --httpd'${origHTTP}' --php'${origPHP}''
      else
        switch=''${switch}' --httpd'${origHTTP}' --php'${origPHP}' --mysql'
      fi
    elif [ "${STACK}" == "Java" ]; then
      if [ "${DBAAS}" == "true" ]; then
        switch=''${switch}' --httpd'${origHTTP}' --tomcat'${origTOM}''
      else
        switch=''${switch}' --httpd'${origHTTP}' --tomcat'${origTOM}' --mysql'
      fi
    elif [ "${STACK}" == "Jamp" ]; then
      if [ "${DBAAS}" == "true" ]; then
        switch=''${switch}' --httpd'${origHTTP}' --tomcat'${origTOM}' --php'${origPHP}''
      else
        switch=''${switch}' --httpd'${origHTTP}' --tomcat'${origTOM}' --php'${origPHP}' --mysql'
      fi
    else
      echo "Tech Stack not specified! Bailing..."
      exit 1
    fi

    if [[ "${SHIB}" == "true" || "${SHIB}" == "True" ]]; then
      switch=''${switch}' --shib'
    fi

    provision=`eval /usr/bin/python /opt/ko/scripts/lms/provisionCLCSite.py ${switch}`
    if [ "${?}" == "0" ]; then
      echo "Provision CLC site is complete for ${SITE_ID} ${ENV}"
      runScupdate="true"
      # Mark environment provisioned as completed in site json
      updateProvision=`jq '(.AdditionalDatacenters[] | select(.Location=="'${DC}'")) |= .+ {"'${ENV}'": "Provisioned"}' ./${SITE_ID}.json`
      rm -rf ./${SITE_ID}.json
      echo ${updateProvision} > ./${SITE_ID}.json
    else
      echo ${provision}
    fi
  else
    echo "${SITE_ID} ${ENV} is already provisioned. Moving on..."
  fi

  sync=`rsync -avr -e "ssh -l svadmin" --exclude '.svn' ${src}:/opt/ko/site-configs/${SITE_ID}/${lowerEnv}/ /opt/ko/site-configs/${SITE_ID}/${lowerEnv} > /dev/null 2>&1`

  ## Clear out balancer members from other DC
  newVhost=`cat /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts.conf |grep -v ${srcDC}`
  newVhostSSL=`cat /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts-ssl.conf |grep -v ${srcDC}`
  rm /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts.conf
  echo "${newVhost}" >> /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts.conf
  rm /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts-ssl.conf
  echo "${newVhostSSL}" >> /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts-ssl.conf
  svnCheck=`/usr/bin/svn st /opt/ko/site-configs/${SITE_ID}`
  echo "${svnCheck}"
  if [ ! -z ${svnCheck} ]; then
    svnCommit=`/usr/bin/svn commit -m "${SITE_ID} / Checking in updates to from the existing datacenter" /opt/ko/site-configs/${SITE_ID}`
    echo "Commiting updates to vhost files from the existing datacenter"
  fi

  if [[ "${STACK}" == "Java" || "${STACK}" == "Jamp" ]]; then
    echo "`date +"%c"`: This is a Java site, so please remember to login to the ${DC} LMS server and update the context.xml with the new database location!!"
  fi
}

function createHiearadata {
  getServers=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name | contains("'${DC}'")) | .Name' ./${SITE_ID}.json`
  allServers=`echo -n "${getServers}"|tr '\n' ','`
  numServers=$(( `echo $allServers | awk -F "," '{print NF-1}'` + 2 ))
  for (( s=1 ; s<${numServers} ; s++ )); do
    unset create
    serverName=`echo ${allServers} | awk -F, '{print $'${s}'}'`
    serverType=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${serverName}'") | .Type' ./${SITE_ID}.json`
    if [[ "${serverType}" == "Fileserver" || "${serverType}" == "Memcached" ]]; then
      continue
    fi
    lowerEnv=`echo "${ENV}" | awk '{print tolower($0)}'`
    if [ "${lowerEnv}" == "production" ]; then
      lowerEnv="prod"
    fi
    middleware=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${serverName}'") | .Middleware' ./${SITE_ID}.json`
    if [ "${middleware}" != "Completed" ]; then
      create=`eval /usr/bin/python /opt/ko/scripts/lms/createHieradataNQ.py -u automation -i ${SITE_ID} -e ${lowerEnv} -s ${serverName} -t ${serverType}`
      if [ "${?}" == "0" ]; then
        # Update JSON marking server middleware completed
        newJSON=`jq '(.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Name=="'${serverName}'") | .Middleware) |= "Completed"' ./${SITE_ID}.json`
        rm -rf ./${SITE_ID}.json
        echo ${newJSON} > ./${SITE_ID}.json
        echo "${serverName}.YAML created and ${SITE_ID}.JSON updated!"
        runPupdate="true"
      else
        echo "${create}"
      fi
    else
      echo "${serverName}.yaml already exists, moving on..."
    fi
  done
}

function createSVNRepo {
  subversionCheck=`jq -r '.Subversion' ./${SITE_ID}.json`
  if [ "${subversionCheck}" != "Completed" ]; then
    agency=`jq -r .SiteGroup ./${SITE_ID}.json`
    siteSvnCreate=`/bin/sh /opt/ko/scripts/lms/siteSvnCreate.sh "${SITE_ID}" "${agency}"`
    if [ "${?}" == "0" ]; then
      echo "${SITE_ID} SVN repo has been created. It can be accessed in a browser at: https://svn.ctlko.com/svn/${SITE_ID}/"
      # Mark environment provisioned as completed in site json
      updateSVN=`jq '. |= .+ {"Subversion": "Completed"}' ./${SITE_ID}.json`
      rm -rf ./${SITE_ID}.json
      echo ${updateSVN} > ./${SITE_ID}.json
    else
      echo "Repo create failed! ${siteSvnCreate}"
    fi
  fi
}

function updateAJP {
  lowerEnv=`echo "${ENV}" | awk '{print tolower($0)}'`
  if [ "${lowerEnv}" == "production" ]; then
    lowerEnv="prod"
  fi
  getJavaServers=`jq -r '.Environments[] | select(.Name=="'${ENV}'") | .Servers[] | select(.Type=="webapp") | .Name' ./${SITE_ID}.json`
  javaServers=`echo -n "${getJavaServers}"|tr '\n' ','`
  numJava=$(( `echo ${javaServers} | awk -F "," '{print NF-1}'` + 2 ))
  for (( j=1 ; j<${numJava} ; j++ )); do
    jServName=`echo ${javaServers} | awk -F, '{print $'${j}'}' `
    httpBalancerMember="BalancerMember ajp://${jServName}.ko.cld:8080 connectionTimeout=5 max=100 smax=75 loadfactor=10 route=${jServName} flushpackets=on"
    httpsBalancerMember="BalancerMember ajp://${jServName}.ko.cld:8443 connectionTimeout=5 max=100 smax=75 loadfactor=10 route=${jServName} flushpackets=on"

    httpCheck=`grep ${jServName} "/opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts.conf"`
    if [ -z ${httpCheck} ]; then
      newHTTP=`awk '/Proxy\ balancer\:\/\/ajpclu1/{ print; print "        '${httpBalancerMember}'"; next }1' /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts.conf`
      rm /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts.conf
      echo ${newHTTP} > /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts.conf
      runScupdate="true"
    fi

    httpsCheck=`grep ${jServName} "/opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts-ssl.conf"`
    if [ -z ${httpsCheck} ]; then
      newHTTPS=`awk '/Proxy\ balancer\:\/\/ajpclu1/{ print; print "        '${httpsBalancerMember}'"; next }1' /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts-ssl.conf`
      rm /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts-ssl.conf
      echo ${newHTTPS} > /opt/ko/site-configs/${SITE_ID}/${lowerEnv}/web/conf/vhosts-ssl.conf
      runScupdate="true"
    fi
  done
  svnCheck=`/usr/bin/svn st /opt/ko/site-configs/${SITE_ID}`
  echo "${svnCheck}"
  if [ ! -z ${svnCheck} ]; then
    svnCommit=`/usr/bin/svn commit -m "${SITE_ID} / Updating AJP Balanacer Members for Provisioning" /opt/ko/site-configs/${SITE_ID}`
    echo "Commiting updates to AJP Proxy Balancer Members for ${SITE_ID}"
  fi
}

getSiteInfo;
echo ""
if [[ "${STACK}" == "Java" || "${STACK}" == "Lamp" || "${STACK}" == "Jamp" ]]; then
  if [ "${ADD_DC}" != "" ]; then
    provisionSecondSite;
    echo ""
  else
    provisionSite;
    echo ""
  fi
  createHiearadata;
  echo ""
fi
if [ "${ADD_DC}" == "" ]; then
  createSVNRepo;
  echo ""
fi
if [[ "${STACK}" == "Java" || "${STACK}" == "Jamp" ]]; then
  updateAJP;
fi
if [ "${runPupdate}" == "true" ]; then
  echo "Running pupdate.sh on puppetmaster"
  ssh -t -T -q -i ~/.ssh/koauto-id_rsa koauto@$puppetMaster "sudo /opt/ko/scripts/puppet/pupdate.sh;" 1> /dev/null
fi
if [ "${runScupdate}" == "true" ]; then
  echo "Running scupdate on puppetmaster"
  ssh -t -T -q -i ~/.ssh/koauto-id_rsa koauto@$puppetMaster "sudo /opt/ko/scripts/puppet/scupdate.sh" 1> /dev/null
fi
updateOrchestrate;

# Cleanup
rm ./${SITE_ID}.json

