#!/bin/bash

readConfig() {
  local configKey=$1
  local outputVariableName=$2
  local defaultValue=$3

  local value=$(yq ".${configKey}" ${confFile})

  if [ -z "${value}" ] || [ "null" == "${value}" ]
  then
    if [ -n "${defaultValue}" ]
    then
      value=${defaultValue}
    else
      echo "Did not find configuration value for '${configKey}', ${confFile} is not correct" 2>&1
      exit 1
    fi
  fi
  # Create a new, global (-g) variable using the name passed into the function
  declare -g ${outputVariableName}=${value}
  echo "  ${configKey}: ${value}"
}

export -f readConfig

ensureDir() {
  local dir=$1
  if [ ! -d ${dir} ]
  then
    mkdir -p ${dir}
  fi
}

export -f ensureDir

downloadFile() {
  local url=$1
  local filePath=$2
  curl --silent --cert ${cert} --key ${key} --cert-type PEM ${url} -o ${filePath}
  if [ $? -ne 0 ]
  then
    echo "Unable to download '${url}' to '${filePath}': curl exited with a non-zero exit code" 1>&2 
    return false
  fi
  return $(true)
}

downloadToCache() {
  domain=$1
  file=$2

  ensureDir ${cacheDir}/${domain}
  downloadFile ${certificateServerUrl}/${domain}/${file} ${cacheDir}/${domain}/${file}
  return $?
}

differsFromCache() {
  local domain=$1
  local file=$2

  diff ${cacheDir}/${domain}/${file} ${targetDir}/${domain}/${file} >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    # There are differences between the files
    
    return $(true)
  fi
  return $(false)
}

updateFromCache() {
  domain=$1
  file=$2

  ensureDir ${targetDir}/${domain}
  cp ${cacheDir}/${domain}/${file} ${targetDir}/${domain}/${file}

  if [ $? -ne 0 ]
  then
    echo "Could not copy '${cacheDir}/${domain}/${file}' to '${targetDir}/${domain}/${file}': cp exited with a non-zero exit code" 1>&2
    return $(false)
  fi

  # Check for a mode setting, this is typicaly used for private key files to ensure they are locked down
  yq -e ".certs[] | select(.name == \"${domain}\").files[] | select(.name == \"${file}\") | has(\"mode\")" ${confFile} 1>/dev/null 2>&1
  if [ $? -eq 0 ]
  then
    # This file has a mode set
    local mode=$(yq ".certs[] | select(.name == \"${domain}\").files[] | select(.name == \"${file}\").mode" ${confFile})
    chmod ${mode} ${targetDir}/${domain}/${file}
    if [ $? -ne 0 ]
    then
      echo "Could not chmod '${targetDir}/${domain}/${file}' to '${mode}': chmod exited wwith a non-zero exit code" 1>&2
      return $(false)
    fi
  fi
  return $(true)
}

processDomain() {
  local domain=$1
  local files=$2

  echo "Processing domain: '${domain}'"
  local domainUpdated=1
  for file in ${files}
  do
    if downloadToCache ${domain} ${file} 
    then
      if differsFromCache ${domain} ${file}
      then
        domainUpdated=$(true)
        updateFromCache ${domain} ${file}
      fi
    else
      return $(false)
    fi
  done
  return ${domainUpdated}
}

######################
## BEGIN MAIN SCRIPT #
#####################
if [ ${UID} -ne 0 ]
then
  echo "You must be root to run this" >&2
  exit 1
fi

confFile=$1

if [ -z "${confFile}" ]
then
  # Default the value
  confFile=/etc/certSync/certSync.yml
fi

export confFile

# read the config from confFile and populate the variables
echo "Reading configuration from ${confFile}..."
echo "Configuration:"
readConfig certificate-server-url certificateServerUrl
readConfig conf-dir confDir
readConfig certificate-server-key key
readConfig certificate-server-cert cert
readConfig certificate-target-dir targetDir
readConfig cache-dir cacheDir /var/cache/certSync

ensureDir ${cacheDir}

for domain in $(yq '.certs[].name' ${confFile})
do
  files=$(yq ".certs[] | select(.name == \"${domain}\").files[].name" ${confFile})
  if processDomain ${domain} "${files}" 
  then
    scripts=$(yq ".certs[] | select(.name == \"${domain}\").scripts[]" ${confFile})
    for script in $scripts
    do
      echo "Running '${script}' for domain '${domain}'"
      echo "############## Begin '${script} stdout ##############"
      ${script} ${domain}
      echo "############## End '${script} stdout ################"
      if [ $? -ne 0 ]
      then
        echo "'${script}' exited with a non-zero exit code"
      fi
    done
  else
    echo "No changes found for '${domain}', skipping script execution" 2>&1
  fi
done
