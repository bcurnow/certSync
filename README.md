# certSync
Bash script to keep certificates in sync.

It supports two modes:
- `http` - Downloads the certificates from a URL which is secured with mTLS
- `directory` - Synchronizes two directories (e.g. the certBot live directory to another directory)

This was built to handle my local network which I manage with a combination of a custom OpenSSL CA for mTLS and Let's Encrypt for everything else.

I wanted to way to manage the renewals across the various machines as some certificates are shared (I have a wildcard cert for my internal domain) and I didn't want to configure certbot everywhere.

I settled on having a single machine which manaages all the Let's Encrypt certificates (with certBot) as well as the mTLS OpenSSL CA. I then expose those certificates (and keys) via Nginx with mTLS.

# Installation

## install.sh

Run the following command: ```curl --location https://github.com/bcurnow/certSync/raw/main/install.sh | sudo bash```

This will install the dependencies, create the /opt/certSync and /etc/certSync directory structures and places [certSync.sh](certSync.sh) in /opt/certSync and [certSync.yml.template](certSync.yml.template) in /etc/certSync.

Running ```curl --location https://github.com/bcurnow/certSync/raw/main/install.sh | sudo bash -s update``` will only get the latest from Github and skip dependency and directory creation.

## Manual

### Dependencies

Install the following packages:
* curl
* tar

Install at least version 4.35.1 of [yq](https://github.com/mikefarah/yq).

Download [certSync.sh](certSync.sh) and [certSync.yml.template](certSync.yml.template).

# certSync Configuration

certSync is configured by a YAML fiile. Please see (certSync.yml.template) for an example.

# Example Nginx Configuration

I run Nginx in a docker container, here is the relevant section of the docker-compose.yml I use:
```
version: '3.9'
services:
  internal-proxy:
    container_name: internal-proxy
    image: nginx:1-alpine
    ports:
      - 443:443/tcp
    restart: always
    volumes:
      - type: bind
        source: /etc/internal-proxy/nginx.conf
        target: /etc/nginx/nginx.conf
        read_only: true
      - type: bind
        source: /etc/internal-proxy/templates/
        target: /etc/nginx/templates
        read_only: true
      - type: bind
        source: /etc/docker-certs/
        target: /certs
        read_only: true
```

The certificates are hosted out of the /etc/docker-certs directory, within that directory I have a sub-directory for each domain that Let's Encrypt manages plus a client-auth directory which costs the internal OpenSSL certificate authority.

Here's a snippet of the Nginx configuration:
```
server {
  listen 443 ssl;
  server_name <your server name here>;
  include conf.d/ssl-common;
  include conf.d/origin-cert;
  ssl_client_certificate /certs/client-auth/ca.crt;
  ssl_verify_client optional;
  root /certs;

  location / {
    if ($ssl_client_verify != SUCCESS) {
      return 403;
    }

    try_files $uri =404;
  }
}
```

The Nginx instance is set up with simply a trusted CA and any certificate issued by that CA can see all the certificates and keys. This could be imporved by setting up specific certificates to get access to specific directories but that really felt overkill.

The /etc/docker-certs directory is then mapped to /certs within the various docker containers.

# OpenSSL CA
The OpenSSL CA is created using the following commands:
- `openssl genrsa -aes256 -out ca.key 4096` - Generates a new 4096 key using AES256
- `openssl req -x509 -new -nodes -key ca.key -sha256 -days 1826 -out ca.crt -subj "/CN=<Your CA Name Here>"` - This creates a new certificate using the key we just generated
- `echo "00" > ca.srl` - This initializes the certificate authorities serial file which we'll use in a minute

For each machine that needs to sync up their certificates, I generate a client certificate using the following commands:
- `openssl req -new -nodes -out <server host name here>.csr -newkey rsa:4096 -keyout <server host name here>.key -subj "/CN=<server host name here>"` - Creates a new certificate signing request for a particular host
- `openssl x509 -req -in $<server host name here>.csr -CA ca.crt -CAkey ca.key -CAserial ca.srl -out <server host name here>.crt -days 365 -sha256` - Signs the certificate using our OpenSSL certificate authority
- `rm <server host name here>.csr` - This is the signing request file, no longer needed after we're done
