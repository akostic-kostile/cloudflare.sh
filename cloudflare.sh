#!/usr/bin/env bash

## utils
JQ="$(which jq) --raw-output"
GREP="$(which grep)"
CURL="$(which curl) --silent --show-error --location --header Content-Type:application/json" # -sSL

## global vars
CF_API="https://api.cloudflare.com/client/v4"

## global vars, will be parsed from cli args
API_TOKEN=""
HOST_NAME=""
ZONE_NAME=""
DESTINATION=""
DELETE="false"
TTL=1
PROXIED="false"

## functions
_usage() {
cat << EOF
Usage: ./cloudflare.sh [options...]
    --api-token <token>         Token for authentication to CF API. String. Required parameter.
    --hostname <hostname>       Hostname you are adding/deleting. String. Required parameter.
    --zone  <zone_name>         Zone in which you are adding/deleting the hostname. String. Required parameter.
    --destination <destination> Destination that the hostname will point to, either a FQDN or IPv4 address. String. Required parameter.
    --ttl <ttl>                 Time to live. if --proxied TTL will always be set to 1 (auto). Default is 1 (auto). Int 1 or 60 - 86400. Optional parameter.
    --proxied                   If CF CDN should be active. if --proxied DNS will return CF IPs hiding the actual destination. If omitted defaults to false and DNS will return actual destination. Optional parameter.
    --delete                    If we are deleting the record. If omitted defaults to false. Optional parameter.
Example:
    Add: ./cloudflare.sh --api-token "$VALID_TOKEN" --hostname "akostic" --zone "3rd-eyes.com" --destination "www.google.com" --ttl 3600
    Delete: ./cloudflare.sh --api-token "$VALID_TOKEN" --hostname "akostic" --zone "3rd-eyes.com" --delete
EOF
}

_validate_api_token() {
    local response

    echo "Validating API token."
    response="$($CURL --request GET "${CF_API}/user/tokens/verify" \
        --header "Authorization: Bearer ${API_TOKEN}" 2>&1
    )"
    ## did curl successfully contact CF API?
    if ! [ $? -eq 0 ]; then
        echo "curl failed. Error message: '$response'"
        exit 1
    fi
    ## does CF API indicate success?
    if ! [ "$(echo $response | $JQ '.success')" == "true" ]; then
        echo "CF API does not indicate success. CF API response: '$response'"
        exit 2
    fi

    echo "Success. CF API response: '$response'."
}

_get_dns_zone() {
    local zone_name=$1
    local response

    response="$($CURL --request GET "${CF_API}/zones?name=${zone_name}" \
        --header "Authorization: Bearer ${API_TOKEN}" 2>&1 \
    )"
    ## did curl successfully contact CF API?
    if ! [ $? -eq 0 ]; then
        echo "curl failed. Error message: '$response'."
        exit 1
    fi
    ## does CF API indicate success?
    if ! [ "$(echo $response | $JQ '.success')" == "true" ]; then
        echo "CF API does not indicate success. CF API response: '$response'."
        exit 2
    fi
    ## did we actually get a result back?
    if ! [ "$(echo $response | $JQ '.result | length')" -eq 1 ]; then
        echo "CF API returned no results. Either your token is lacking necessary privileges or zone you have requested '$zone_name' does not exist. CF API response: '$response'."
        exit 3
    fi

    echo $response | $JQ '.result[0]'
}

_get_dns_record() {
    local fqdn=$1
    local response

    response="$($CURL --request GET "${CF_API}/zones/${ZONE_ID}/dns_records?name=${fqdn}" \
        --header "Authorization: Bearer ${API_TOKEN}" 2>&1 \
    )"
    ## did curl successfully contact CF API?
    if ! [ $? -eq 0 ]; then
        echo "curl failed. Error message: '$response'"
        exit 1
    fi
    ## does CF API indicate success?
    if ! [ "$(echo $response | $JQ '.success')" == "true" ]; then
        echo "CF API does not indicate success. CF API response: '$response'."
        exit 2
    fi
    ## did we actually get a result back?
    if ! [ "$(echo $response | $JQ '.result | length')" -eq 1 ]; then
        echo "CF API returned no results. DNS record you have requested '${fqdn}' does not exist or you lack privileges to view it. CF API response: '$response'."
        exit 3
    fi

    echo $response | $JQ '.result[0]'
}

_delete_dns_record() {
    local dns_record_id=$1
    local response

    echo "Deleting DNS record ID '$dns_record_id' from zone ID '$ZONE_ID'."
    response="$($CURL --request DELETE "${CF_API}/zones/${ZONE_ID}/dns_records/${dns_record_id}" \
        --header "Authorization: Bearer ${API_TOKEN}" 2>&1 \
    )"
    ## did curl successfully contact CF API?
    if ! [ $? -eq 0 ]; then
        echo "curl failed. Error message: '$response'."
        exit 1
    fi
    ## does CF API indicate success?
    if ! [ "$(echo $response | $JQ '.success')" == "true" ]; then
        echo "CF API does not indicate success. CF API response: '$response'."
        exit 2
    fi

    echo "Success. CF API response: '$response'."
}

_add_dns_record() {
    local host_name=$1
    local destination=$2
    local ttl=${3:-1} # default value is 1
    local proxied=${4:-false} # default value is false
    local dns_record_template='{"type":"","name":"","content":"","ttl":1,"proxied":false}' # TTL 1 means auto
    local dns_record_json
    local dns_record_type
    local response

    ## https://stackoverflow.com/questions/106179/regular-expression-to-match-dns-hostname-or-ip-address
    echo "Validating hostname."
    if ! echo "${host_name}" | grep -E '^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$' > /dev/null; then
        echo "Hostname '${host_name}' is not a valid DNS name."
        exit 3
    fi
    echo "Hostname '${host_name}' is valid."

    echo "Validating destination."
    if echo $destination | grep -E '^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$' > /dev/null; then
        dns_record_type="A"
    elif echo $destination | grep -E '^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\-]*[a-zA-Z0-9])\.)*([A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9\-]*[A-Za-z0-9])$' > /dev/null; then
        dns_record_type="CNAME"
    else
        echo "Destination '$destination' is neither a valid IPv4 address nor a valid hostname."
        exit 3
    fi
    echo "Destination '$destination' is a valid '$dns_record_type' type record."

    echo "Validating TTL."
    if ! [ $TTL -eq 1 ]; then
        if ! { [ $TTL -ge 60 ] && [ $TTL -le 86400 ] ;}; then
            echo "TTL must be 60 <= TTL <= 86400 or 1 for auto. You have provided '$TTL'."
            exit 3
        fi
    fi
    echo "TTL '$TTL' is valid."

    echo "Adding '${host_name}.${ZONE_NAME} ${dns_record_type} ${destination}'"
    ## --arg converts to string while --argjson keeps the correct type, in our case int for ttl and bool for proxied
    dns_record_json="$(echo $dns_record_template \
        | $JQ --compact-output \
            --arg name $host_name \
            --arg type $dns_record_type \
            --arg content $destination \
            --argjson ttl $ttl \
            --argjson proxied $proxied \
            ' .name = $name | .type = $type | .content = $content | .ttl = $ttl | .proxied = $proxied' 2>&1)"

    response="$($CURL --request POST "${CF_API}/zones/${ZONE_ID}/dns_records" \
        --header "Authorization: Bearer ${API_TOKEN}" \
        --data $dns_record_json 2>&1 \
    )"
    ## did curl successfully contact CF API?
    if ! [ $? -eq 0 ]; then
        echo "curl failed. Error message: '$response'."
        exit 1
    fi
    ## does CF API indicate success?
    if ! [ "$(echo $response | $JQ '.success')" == "true" ]; then
        echo "CF API does not indicate success. Original request json: '$dns_record_json'. CF API response: '$response'."
        exit 2
    fi

    echo "Success. CF API response: '$response'."
}

## main

## if no args are provided display usage and exit
[ $# -eq 0 ] && _usage && exit 0

## parse cli args
while [ $# -gt 0 ]; do
  case $1 in
    --api-token)
      API_TOKEN="$2"
      shift # past argument
      shift # past value
      ;;
    --hostname)
      HOST_NAME="$2"
      shift # past argument
      shift # past value
      ;;
    --zone)
      ZONE_NAME="$2"
      shift # past argument
      shift # past value
      ;;
    --destination)
      DESTINATION="$2"
      shift # past argument
      shift # past value
      ;;
    --ttl)
      TTL=$2
      shift # past argument
      shift # past value
      ;;
    --proxied)
      PROXIED="true"
      shift # past argument
      ;;
    --delete)
      DELETE="true"
      shift # past argument
      ;;
    *)
      echo "Unknown option '$1'."
      _usage
      exit 1
      ;;
  esac
done

## as a minimum we need to have api key, hostname, zone, and destination (if $DELETE == false) set
if [ -z "$API_TOKEN" ]; then
    echo "You must provide a valid API token to use this script."
    _usage
    exit 1
fi
if [ -z "$HOST_NAME" ]; then
    echo "You must provide hostname to use this script."
    _usage
    exit 1
fi
if [ -z "$ZONE_NAME" ]; then
    echo "You must provide zone name to use this script."
    _usage
    exit 1
fi
if [ -z "$DESTINATION" ] && [ "$DELETE" == "false" ]; then
    echo "You must provide destination to use this script."
    _usage
    exit 1
fi

## first we check if the token is valid
_validate_api_token

## then we get the zone
ZONE="$(_get_dns_zone "$ZONE_NAME")"
if ! [ $? -eq 0 ]; then
    echo $ZONE
    exit 1
fi

## we get zone ID from the zone
ZONE_ID="$(echo $ZONE | $JQ '.id')"
echo "Zone ID for '$ZONE_NAME' is '$ZONE_ID'."


if $DELETE; then
    echo "Deleting '${HOST_NAME}.${ZONE_NAME}'."
    DNS_RECORD="$(_get_dns_record "${HOST_NAME}.${ZONE_NAME}")"
    case $? in
        0) ;; # already exists, do nothing, we'll delete it below
        1|2) echo "$DNS_RECORD" && exit 1 ;; # curl failed, or we did not get success from API, exit with error
        3) echo "$DNS_RECORD" && exit 0 ;; # record does not exist, exit without error
    esac

    DNS_RECORD_ID="$(echo $DNS_RECORD | $JQ '.id')"
    echo "DNS record ID for '${HOST_NAME}.${ZONE_NAME}' is '$DNS_RECORD_ID'"

    _delete_dns_record "$DNS_RECORD_ID"
else
    echo "Adding '${HOST_NAME}.${ZONE_NAME}'."
    ## does the record already exist?
    DNS_RECORD="$(_get_dns_record "${HOST_NAME}.${ZONE_NAME}")"
    case $? in
        0) DNS_RECORD_ID="$(echo $DNS_RECORD | $JQ '.id')" \
            && echo "Hostname '$HOST_NAME' already exists in zone '$ZONE_NAME', DNS record ID is '$DNS_RECORD_ID'" \
            && _delete_dns_record "$DNS_RECORD_ID" ;; # already exists, delete it, we'll add it again below
        1|2) echo "$DNS_RECORD" && exit 1 ;; # curl failed or we did not get success from CF API, exit with error
        3) ;; # record does not exist, do nothing, we are adding it below
    esac

    _add_dns_record "$HOST_NAME" "$DESTINATION" "$TTL" "$PROXIED"
fi
