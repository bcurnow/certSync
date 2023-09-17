#!/bin/bash

queryConfig() {
  local yqQuery=$1
  local outputVariableName=$2
  local defaultValue=$3

  logDebug 2 "Executing query '${yqQuery}' against ${confFile}"
  local value=$(yq "${yqQuery}" ${confFile})
  logDebug 2 "Read '${value}' in ${confFile} using query '${yqQuery}'"

  if [ -z "${value}" ] || [ "null" == "${value}" ]
  then
    if [ -n "${defaultValue}" ]
    then
      # don't log out "null" defaults at level 1
      if [ "null" != "${defaultValue}" ]
      then
        logDebug 0 "Defaulting '${outputVariableName}' to '${defaultValue}'"
      fi
      logDebug 1 "Did not find a value using '${yqQuery}', using default value '${defaultValue}'"
      value=${defaultValue}
    else
      logFatal "Did not find a value using '${yqQuery}', ${confFile} is not correct"
    fi
  fi
  # Create a new, global (-g) variable using the name passed into the function
  logDebug 2 "Setting ${outputVariableName} to '${value}'"
  declare -g ${outputVariableName}="${value}"
}

export -f queryConfig

readConfig() {
  local -i level=$1 
  local yqQuery

  if [ 0 -eq ${level} ]
  then
    local key=$2
    local outputVariableName=$3
    local defaultValue=$4

    logDebug 2 "Root configuration lookup: key: '${key}', outputVariableName: '${outputVariableName}', defaultValue: '${defaultValue}'"
    yqQuery=".${key}"
  elif [ 1 -eq ${level} ]
  then
    local section=$2
    local name=$3
    local key=$4
    local outputVariableName=$5
    local defaultValue=$6

    logDebug 2 "Level ${level} configuration lookup: section: '${section}', name: '${name}', key: '${key}', outputVariableName: '${outputVariableName}', defaultValue: '${defaultValue}'"
    yqQuery=".${section} | select(.name == \"${name}\").${key}"
  elif [ 2 -eq ${level} ]
  then
    local section=$2
    local name=$3
    local subsection=$4
    local subsectionName=$5
    local key=$6
    local outputVariableName=$7
    local defaultValue=$8

    logDebug 2 "Level ${level} configuration lookup: section: '${section}', name: '${name}', subsection: '${subsection}', subsectionName: '${subsectionName}',  key: '${key}', outputVariableName: '${outputVariableName}', defaultValue: '${defaultValue}'"
    yqQuery=".${section} | select(.name == \"${name}\").${subsection} | select(.name == \"${subsectionName}\").${key}"
  elif [ 3 -eq ${level} ]
  then
    local section=$2
    local name=$3
    local subsection=$4
    local subsectionName=$5
    local subsubsection=$6
    local subsubsectionName=$7
    local key=$8
    local outputVariableName=$9
    local defaultValue=${10}

    logDebug 2 "Level ${level} configuration lookup: section: '${section}', name: '${name}', subsection: '${subsection}', subsectionName: '${subsectionName}',  subsubsection: '${subsubsection}', subsubsectionName: '${subsubsectionName}', key: '${key}', outputVariableName: '${outputVariableName}', defaultValue: '${defaultValue}'"
    yqQuery=".${section} | select(.name == \"${name}\").${subsection} | select(.name == \"${subsectionName}\").${subsubsection} | select(.name == \"${subsubsectionName}\").${key}"
  else
    logFatal "Unsupported level '${level}' in configuration lookup"
  fi
  queryConfig "${yqQuery}" ${outputVariableName} ${defaultValue}
}

export -f readConfig

logDebug() {
  local level=$1
  local msg=$2
  if [ -n "${debug}" ] && [ ${debug} -ge ${level} ]
  then
    echo -e "${msg}"
  fi
}

export -f logDebug

logFatal() {
  local msg=$1
  local -i exitCode=$2

  if [ -z "${exitCode}" ]
  then
    exitCode=1
  fi

  echo -e "${msg}" 1>&2
  exit ${exitCode} 
}

export -f logFatal

ensureDir() {
  local dir=$1
  logDebug 2 "Checking for '${dir}'"
  if [ ! -d ${dir} ]
  then
    logDebug 1 "Creating ${dir}"
    mkdir -p ${dir}
  fi
}

export -f ensureDir

downloadFile() {
  local url=$1
  local file=$2
  local cert=$3
  local key=$4

  logDebug 1 "Downloading '${url}' to '${file}'"
  logDebug 2 "Using cert '${cert}' and key '${key}'"
  curl --silent --cert ${cert} --key ${key} --cert-type PEM ${url} -o ${file}

  if [ $? -ne 0 ]
  then
    logFatal "Unable to download '${url}' to '${filePath}': curl exited with a non-zero exit code"
  fi
}

filesDiffer() {
  local left=$1
  local right=$2

  logDebug 2 "Comparing ${left} to ${right}"
  diff ${left} ${right} >/dev/null 2>&1
  if [ $? -ne 0 ]
  then
    # There are differences between the files
    logDebug 1 "Found differences between ${left} and ${right}"
    return $(true; echo $?)
  fi
  logDebug 1 "No differences between ${left} and ${right}"
  return $(false ; echo $?)
}

updateFile() {
  local sourceDir=$1
  local targetDir=$2
  local domain=$3
  local file=$4
  local syncName=$5

  ensureDir ${targetDir}/${domain}
  logDebug 1 "Copying ${sourceDir}/${domain}/${file} to ${targetDir}/${domain}/${file}"
  cp ${sourceDir}/${domain}/${file} ${targetDir}/${domain}/${file}

  if [ $? -ne 0 ]
  then
    logFatal "Could not copy '${sourceDir}/${domain}/${file}' to '${targetDir}/${domain}/${file}': cp exited with a non-zero exit code"
  fi

  changeMode ${syncName} ${domain} ${file} ${targetDir}/${domain}
}

changeMode() {
  local syncName=$1
  local domain=$2
  local file=$3
  local dir=$4

  # Check for a mode setting, this is typicaly used for private key files to ensure they are locked down
  readConfig 3 ${syncSection} ${syncName} ${domainsSection} ${domain} ${filesSection} ${file} mode fileMode "null"

  if [ "null" != "${fileMode}" ]
  then
    # This file has a mode set
    logDebug 1 "Changing mode on ${dir}/${file} to '${fileMode}'"
    chmod ${fileMode} ${dir}/${file}

    if [ $? -ne 0 ]
    then
      logFatal "Could not chmod '${file}' to '${fileMode}': chmod exited wwith a non-zero exit code"
    fi
  fi
}

processHttpSync() {
  local syncName=$1
  local domain=$2

  echo "Processing http sync with name '${syncName}' and domain: '${domain}'"
  readConfig 1 ${syncSection} ${syncName} cache-dir cacheDir /etc/certSync/cache
  readConfig 1 ${syncSection} ${syncName} target-dir targetDir
  readConfig 1 ${syncSection} ${syncName} url url
  readConfig 1 ${syncSection} ${syncName} cert cert 
  readConfig 1 ${syncSection} ${syncName} key key
  readConfig 2 ${syncSection} ${syncName} ${domainsSection} ${domain} ${filesSection}.name files

  logDebug 1 "Cache directory: '${cacheDir}'"
  logDebug 1 "Target directory: '${targetDir}'"
  logDebug 1 "URL: '${url}'"
  logDebug 1 "Certificate: '${cert}'"
  logDebug 1 "Key: '${key}'"
  logDebug 1 "Files:\n${files}"

  ensureDir ${cacheDir}

  local -i domainUpdated=$(false ; echo $?)
  for file in ${files}
  do
    logDebug 1 "Processing file: '${file}'"
    ensureDir ${cacheDir}/${domain}
    downloadFile ${url}/${domain}/${file} ${cacheDir}/${domain}/${file} ${cert} ${key}
    if filesDiffer ${cacheDir}/${domain}/${file} ${targetDir}/${domain}/${file}
    then
      updateFile ${cacheDir} ${targetDir} ${domain} ${file} ${syncName}
      domainUpdated=$(true ; echo $?)
    fi
  done

  if [ $(true ; echo $?) -eq ${domainUpdated} ]
  then
    echo "${domain} updated, executing scripts"
    executeScripts ${syncName} ${domain}
  else
    echo "${domain} has no changes, skipping script execution"
  fi
}

processDirectorySync() {
  local syncName=$1
  local domain=$2
  echo "Processing directory sync with name '${syncName}' and domain '${domain}'"
  readConfig 1 ${syncSection} ${syncName} source-dir sourceDir
  readConfig 1 ${syncSection} ${syncName} target-dir targetDir
  readConfig 2 ${syncSection} ${syncName} ${domainsSection} ${domain} ${filesSection}.name files

  logDebug 1 "Source directory: '${sourceDir}'" 
  logDebug 1 "Target directory: '${targetDir}'"
  logDebug 1 "Files:\n${files}"

  local -i domainUpdated=$(false ; echo $?)
  for file in ${files}
  do
    if filesDiffer ${sourceDir}/${domain}/${file} ${targetDir}/${domain}/${file}
    then
      updateFile ${sourceDir} ${targetDir} ${domain} ${file} ${syncName}
      domainUpdated=$(true ; echo $?)
    fi
  done

  if [ $(true ; echo $?) -eq ${domainUpdated} ]
  then
    echo "${domain} updated, executing scripts"
    executeScripts ${syncName} ${domain}
  else
    echo "${domain} has no changes, skipping script execution"
  fi
}

executeScripts() {
  local syncName=$1
  local domain=$2

  # Scripts are optional so don't fail if we can't find them
  readConfig 2 ${syncSection} ${syncName} ${domainsSection} ${domain} ${scriptsSection} scripts "null"
  logDebug 2 "Found scripts: '${scripts}'"

  if [ "null" != "${scripts}" ]
  then
    # There are scripts, run them
    logDebug 0 "${domain} changed, executing scripts"
    for script in ${scripts}
    do
      # Export the set of variables to make available in the scripts
      export domain
      export scriptsDir
      export sourceDir
      export syncName
      export targetDir

      logDebug 0 "############## Begin '${scriptsDir}/${script} output ##############"

      if [ ${debug} -gt -1 ]
      then
        ${scriptsDir}/${script} 2>&1
      else
        ${scriptsDir}/${script} >/dev/null 2>&1
      fi

      local -i ret=$? 

      logDebug 0 "############## End '${scriptsDir}/${script} output ################"

      if [ ${ret} -ne 0 ]
      then
        logFatal "'${scriptsDir}/${script}' exited with a non-zero exit code" ${ret}
      fi
    done
  else	
    logDebug 0 "${domain} changed but no scripts found"
  fi
}

######################
## BEGIN MAIN SCRIPT #
#####################
if [ ${UID} -ne 0 ]
then
  logFatal "You must be root to run this"
fi

declare -i debug=-1
export debug

while [ $# -gt 0 ]
do
  case $1 in
    -c|--config)
      confFile=$2
      shift
      shift
      ;;
    -d|--debug)
      if [ -z ${debug} ]
      then
        echo "Debug logging enabled"
        debug=0
      else
        debug+=1
      fi
      shift
      ;;
    *|-*|--*)
      logFatal "Unknown option $1"
      ;;
  esac
done

logDebug 0 "Debug logging level: ${debug}"

if [ -z "${confFile}" ]
then
  # Default the value
  confFile=/etc/certSync/certSync.yml
  logDebug 0 "Defaulting config file to '${confFile}'"
fi
export confFile

# read the config from confFile and populate the variables
logDebug 0 "Reading configuration from '${confFile}'"
readConfig 0 conf-dir confDir
logDebug 0 "Configuration directory: '${confDir}'"
readConfig 0 scripts-dir scriptsDir
logDebug 0 "Scripts directory: '${scriptsDir}'"

# Global variables
syncSection=sync[]
export syncSection
domainsSection=domains[]
export domainsSection
filesSection=files[]
export filesSection
scriptsSection=scripts[]
export scriptsSection

# Main loop
readConfig 0 ${syncSection}.type syncTypes
logDebug 2 "Found syncTypes: '${syncTypes}'"
for syncType in ${syncTypes}
do
  logDebug 1 "Processing syncType '${syncType}'"
  queryConfig ".${syncSection} | select(.type == \"${syncType}\").name" syncNames
  logDebug 2 "Found syncNames: '${syncNames}'"
  for syncName in ${syncNames}
  do
    logDebug 1 "Processing syncName: '${syncName}'"
    queryConfig ".${syncSection} | select(.name == \"${syncName}\").${domainsSection}.name" domains
    logDebug 2 "Found domains: '${domains}'"
    for domain in ${domains}
    do
      logDebug 1 "Processing domain: '${domain}'"
      process${syncType^}Sync ${syncName} ${domain}
    done
  done
done
