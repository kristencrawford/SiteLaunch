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
#    addUser.sh
#    Kristen Crawford <kristen.crawford@centurylink.com>
#
#    Add new users and groups to Active Directory and the CLC Portal 
#
#### Changelog
#
##   2015.11.06 <kristen.crawford@centurylink.com>
## - Initial release


## Set variables configured in package.manifest
IFS='%'
SITE_ID="${1}"

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

#Ensure pwgen is installed
if [ ! `rpm -qa | grep pwgen-` ]; then
  yum install pwgen -y
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
    ACCT=`jq -r .CLCAccountAlias ./${SITE_ID}.json`
    SERVICETIER=`jq -r .ServiceTier ./${SITE_ID}.json`
    CURRENT_OWNER=`jq -r .SiteGroup ./${SITE_ID}.json`
    FIRST_NAME=`jq -r '.Requestors[] | select(.Access=="_NewUser_") | .FirstName' ./${SITE_ID}.json`
    LAST_NAME=`jq -r '.Requestors[] | select(.Access=="_NewUser_") | .LastName' ./${SITE_ID}.json`
    EMAIL_ADDRESS=`jq -r '.Requestors[] | select(.Access=="_NewUser_") | .Email' ./${SITE_ID}.json`
    GROUP=`jq -r .SiteGroup ./${SITE_ID}.json`
    AD_USERNAME=`echo ${FIRST_NAME:0:1}${LAST_NAME} | awk '{print tolower($0)}'`
    CN="${FIRST_NAME} ${LAST_NAME}"
    PORTAL_USERNAME="${FIRST_NAME}.${LAST_NAME}.${ACCT}"
  else
    echo "`date +"%c"`: Foundation Blueprint has not been run yet, you must run this first! Bailing..."
    exit 1
  fi

  if [[ -z "${FIRST_NAME}" || -z "${LAST_NAME}" || -z "${EMAIL_ADDRESS}" ]]; then
    echo "No new users to add.  Moving on.."
    exit
  fi
}


function updateOrchestrate
{
  # Updating JSON with completed status for new user
  sed -i -e "s/_NewUser_/Completed/g" ./${SITE_ID}.json #

  # Commit the change to Orchestrate
  JSON=`cat ./${SITE_ID}.json`
  curl -is "https://${ORCH_ENDPOINT}/v0/${COLLECTION}/${SITE_ID}" -XPUT -H "Content-Type: application/json" -u "$ORCH_APIKEY:" -d "${JSON}" -o /dev/null
}

### Check if user already exists in AD ###
function searchUser {
  userCheck=`ldapsearch -H ldap://va1tcccad00201.ko.cld -x -b DC=KO,DC=CLD -b "CN=${CN},OU=Developers,DC=KO,DC=CLD" -D "CN=user,OU=Service Accounts,DC=KO,DC=CLD" -w password samaccountname | grep sAMAccountName`
  if [ ! -z ${userCheck} ]; then
      #Return yes if found
      echo "yes"
  fi
}

function searchGroup {
  agencyCheck=`ldapsearch -H ldap://va1tcccad00201.ko.cld -x -b DC=ko,DC=cld -b "CN=${GROUP},OU=DeveloperGroups,DC=KO,DC=CLD" -D "CN=user,OU=Service Accounts,DC=KO,DC=CLD" -w password | grep sAMAccountName | awk -F: '{print tolower($2)}' | sed 's/[[:space:]]//g'`
  if [ -z ${agencyCheck} ]; then
      #Return yes if found
      echo "no"
  fi
}

function searchUserMapping {
  mappingCheck=`ldapsearch -H ldap://va1tcccad00201.ko.cld -x -b DC=ko,DC=cld -b "CN=${CN},OU=Developers,DC=KO,DC=CLD" -D "CN=user,OU=Service Accounts,DC=KO,DC=CLD" -w password | grep memberOf: | awk -F= '{print $2}' | awk -F, '{print $1}' | awk '{print tolower($0)}' | sed 's/[[:space:]]//g'`
  lowerGroup=`echo ${GROUP} | awk '{print tolower($0)}'| sed 's/[[:space:]]//g'`
  for i in ${mappingCheck};do
    if [[ "${i}" == "${lowerGroup}" ]]; then
      echo "yes"
    fi
  done
}

function searchUsers_Portal {

  userSearchJSON="{\"AccountAlias\": \"${ACCT}\"}"

  getAcctUser=`curl -s "https://${ENDPOINT}/REST/User/GetUsers/JSON" -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "${userSearchJSON}"`
  total=$(echo ${getAcctUser} | jq '.Users[] | length' | wc -l)
  acctUsers=`echo ${getAcctUser} | jq -r '.Users[] | .UserName'`
  userList=`echo -n "${acctUsers}"|tr '\n' ','`
  lowerPname=`echo ${PORTAL_USERNAME} | awk '{print tolower($0)}'`
  for (( u=0 ; u<${total} ; u++ ));  do
    name=$(echo ${getAcctUser} | jq -r '.Users['${u}'] | .UserName' | awk '{print tolower($0)}')
    if [ "${name}" == "${lowerPname}" ]; then
      echo ${name}
    fi
  done

}

function addUserAD {
  # Create ldif for user
  cat >./$LAST_NAME.ldif << EOL
dn: CN=${CN},OU=Developers,DC=KO,DC=CLD
objectClass: top
objectClass: person
objectClass: organizationalPerson
objectClass: user
displayName: ${CN}
cn: ${CN}
instanceType: 4
sAMAccountName: ${AD_USERNAME}
mail: ${EMAIL_ADDRESS}
userPrincipalName: ${AD_USERNAME}@KO.CLD
EOL

  # Add user to AD
  add=`ldapadd -x -D "CN=admin_user,OU=Savvis Users,DC=KO,DC=CLD" -w admin_password -f ./${LAST_NAME}.ldif`
  if [ $? != 0 ]; then
    echo "`date +"%c"`: Add ${CN} to Active Directory failed! Go figure out why!"
    exit 1
  fi

  echo "`date +"%c"`: ${add}"

  # Create ldif for password updates
  password=`pwgen -1 -s -y -B`
  pwQuotes=`echo "\"${password}\""`
  unicodePW=`echo -n ${pwQuotes} | iconv -t UTF-16LE | base64`

  cat >./${LAST_NAME}_psswd.ldif << EOL
dn: CN=${CN},OU=Developers,DC=KO,DC=CLD
changetype: modify
replace: unicodePwd
unicodePwd:: ${unicodePW}
-
replace: userAccountControl
userAccountControl: 66048
EOL

  # Set password, password expiration and enable user in AD
  modify=`ldapmodify -D "CN=admin_user,OU=Savvis Users,DC=KO,DC=CLD" -w admin_password -f ./${LAST_NAME}_psswd.ldif`
  if [ $? != 0 ]; then
    echo "`date +"%c"`: Add password for ${CN} failed! Go figure out why!"
    exit 1
  fi

  echo "`date +"%c"`: ${modify}"

  # Get rid of ldifs
  rm ./${LAST_NAME}.ldif
  rm ./${LAST_NAME}_psswd.ldif

  # Write User Info to an email to be sent later..
  echo "Name: ${CN}" >> ${AD_USERNAME}.txt
  echo "Username: ${AD_USERNAME}" >> ${AD_USERNAME}.txt
  echo "Password: ${password}" >> ${AD_USERNAME}.txt
}

function addGroupAD {
  # check if ldif already exists... If so wait till it is gone
  while : ; do
    if [ -f ./groupAdd.ldif ]; then
      sleep 2
    else
      # Create ldif for group 
      cat >./groupAdd.ldif << EOL
dn: CN=${GROUP},OU=DeveloperGroups,DC=KO,DC=CLD
objectClass: top
objectClass: group
sAMAccountName: ${GROUP}
EOL

      # Add user to AD
      groupAdd=`ldapadd -x -D "CN=admin_user,OU=Savvis Users,DC=KO,DC=CLD" -w admin_password -f ./groupAdd.ldif`
      if [ $? != 0 ]; then
        echo "`date +"%c"`: Group ${GROUP} Active Direcotory failed! Go figure out why!"
        exit 1
      fi

      echo "`date +"%c"`: ${groupAdd}"

      # Get rid of ldif
      rm ./groupAdd.ldif
      
      break
    fi
  done
}

### Add User to Group in AD ###
function addUserToGroupAD {
  # Create ldif for user
  cat >./${LAST_NAME}_groupAdd.ldif << EOL
dn: CN=${GROUP},OU=DeveloperGroups,DC=KO,DC=CLD
changetype: modify
add: member
member: CN=${CN},OU=Developers,DC=KO,DC=CLD
EOL

  # Add user to AD
  addUserMapping=`ldapadd -x -D "CN=admin_user,OU=Savvis Users,DC=KO,DC=CLD" -w admin_password -f ./${LAST_NAME}_groupAdd.ldif`
  if [ $? != 0 ]; then
    echo "`date +"%c"`: Add ${CN} to ${GROUP} in Active Directory failed because ${CN} is already part of ${GROUP}" 
  #  exit 1
  else
    echo "`date +"%c"`: ${addUserMapping}"
  fi

  # Get rid of ldifs
  rm ./${LAST_NAME}_groupAdd.ldif

  # Write User Info to an email to be sent later..
  echo "Group: ${GROUP}" >> ${AD_USERNAME}.txt
}

function addUser_Portal {
  #Determine User's Role
  if [ "${SERVICETIER}" == "Gold" ]; then
    ROLE="10"
  elif [ "${SERVICETIER}" == "Silver" ]; then
    ROLE="15"
  elif [ "${SERVICETIER}" == "Bronze" ]; then
    ROLE="9"
  else
    ROLE="null"
  fi
  # Create User Json
  newUserJSON="{\"UserName\": \"${PORTAL_USERNAME}\",\"AccountAlias\":\"${ACCT}\",\"EmailAddress\": \"${EMAIL_ADDRESS}\",\"FirstName\": \"${FIRST_NAME}\",\"LastName\": \"${LAST_NAME}\",\"AlternateEmailAddress\": null,\"Title\": null,\"OfficeNumber\": null,\"MobileNumber\": null,\"AllowSMSAlerts\": false,\"FaxNumber\": null,\"SAMLUserName\": null,\"Roles\":\"${ROLE}\",\"TimeZoneID\": null}"

  createUser=`curl -s "https://${ENDPOINT}/REST/User/CreateUser/JSON"  -XPOST -H "Content-type: application/json" -b "cookies.txt" -d "${newUserJSON}"`
  if [ "`echo "${createUser}" | jq '.StatusCode'`" != "0" ]; then
    echo "`date +"%c"`: Add ${PORTAL_USERNAME} to ${ACCT} Failed! Reason: `echo "${createUser}" | jq '.Message'`"
  else
    echo "`date +"%c"`: ${PORTAL_USERNAME} created in the portal under Account ${ACCT}"
    echo "Portal UserName: ${PORTAL_USERNAME}" >>  ${AD_USERNAME}.txt
  fi
}

## MAIN ##

# Get Site Info from Orchestrate
getSiteInfo;

# Ensure that the request Group matches the existing Group
if [[ "${CURRENT_OWNER}" == "_Group_" || "${GROUP}" == "${CURRENT_OWNER}" ]]; then
  ## Check AD for group, add if not found
  groupFound=$(searchGroup);
  if [ "${groupFound}" == "no" ]; then
    echo "`date +"%c"`: Adding ${GROUP} to Active Directory"
    addGroupAD;
  else
    echo "`date +"%c"`: No need to add ${GROUP} to Active Directory as it already exists"
  fi

  ## Check AD for user, add if not found
  userFound=$(searchUser);
  if [ "$userFound" == "yes" ]; then
    echo "`date +"%c"`: No need to add ${CN} to Active Directory as they already exist"
    # Check AD to ensure user is mapped to the requested group, if not then add
    mappingFound=$(searchUserMapping);
    if [ "${mappingFound}" == "yes" ]; then
      echo "`date +"%c"`: ${CN} is mapped to ${GROUP} in Active Directory"
    else
      echo "`date +"%c"`: Adding ${CN} to ${GROUP} in Active Directory"
      addUserToGroupAD;
    fi
  else
    echo "`date +"%c"`: Adding new user ${CN} to Active Directory and mapping them to ${GROUP}"
    addUserAD;
    addUserToGroupAD;
  fi

  ## Check for User in Acct, add if not found
  getAuth;
  portalUserFound=$(searchUsers_Portal);
  if [ ! -z "${portalUserFound}" ]; then
    echo "`date +"%c"`: Portal User ${portalUserFound} Found"
  else
    addUser_Portal;
  fi

  #Import User and set UI Security for their group
  logonJSON="{\"name\":\"${AD_USERNAME}\",\"authenticationRealmId\":\"d3974d41-4098-4ccc-861a-2a2b8d6868e1\"}"
  curl -u admin:Qu@s! -s -k -X PUT -H "Content-Type: application/json" -d "${logonJSON}" "https://10.128.138.33:8443/rest/security/user/ldap"
  if [ "$?" != "0" ]; then
    echo "`date +"%c"`: ${AD_USERNAME} was not imported into uDeploy!, Add it manually"
    # Exiting as the next step will fail, so no need to run it
    exit 1
  fi

  udGroups=`curl -s -u admin:Qu@s! -k -X GET -H "Content-Type: application/json" https://10.128.138.33:8443/rest/security/groups`
  ID=`echo ${udGroups} | jq '.[] | select(.name=="'${GROUP}'") | .id' | sed "s/\"//g"`
  curl -u admin:Qu@s! -s -k -X PUT "https://10.128.138.33:8443/rest/ui/security/role/8555cab8-3e5e-4364-83f7-165b447a2083/group/${ID}"
  if [ "$?" != "0" ]; then
    echo "`date +"%c"`: ${GROUP} not added to UI Security in uDeploy!, Add it manually"
  fi

  if [ -f ${AD_USERNAME}.txt ]; then
    # Send email to User with new Account info
    mutt -s "New User Info" ${EMAIL_ADDRESS} < ${AD_USERNAME}.txt
    rm ${AD_USERNAME}.txt
  fi

  # Update Site JSON and send updates to Orchestrate
  updateOrchestrate;

else
  echo "`date +"%c"`: The Group requested is not the same as the existing group. If the site has a new owner, update the site json before running addUser. Bailing.."
  exit 1
fi

# cleanup
rm ./${SITE_ID}.json
