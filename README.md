# certSync
Bash script to keep certificates in sync.

It supports two modes:
- `http` - Downloads the certificates from a URL which is secured with mTLS
- `directory` - Synchronizes two directories (e.g. the certBot live directory to another directory)

This was built to handle my local network which I manage with a combination of a custom OpenSSL CA for mTLS and Let's Encrypt for everything else.

I wanted to way to manage the renewals across the various machines as some certificates are shared (I have a wildcard cert for my internal domain) and I didn't want to configure certbot everywhere.

I settled on having a single machine which manaages all the Let's Encrypt certificates (with certBot) as well as the mTLS OpenSSL CA. I then expose those certificates (and keys) via Nginx with mTLS.

# Nginx Configuration

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

# Setting up certSync
Once the Nginx and OpenSSL setups are complete, I put certSync.sh in /opt/certSync and then create the /etc/certSync and /etc/certSync/scripts directories and finally copy the <server host name here>.key and <server host name here>.crt files to /etc/certSync.

I setup cron to run certSync.sh every day.

The configuration file, which I default to /etc/certSync/certSync.yml looks like this:
```
conf-dir: /etc/certSync
scripts-dir: /etc/certSync/scripts
sync:
  - name: nginx-sync
    type: http
    cache-dir: /etc/certSync/cache
    target-dir: /etc/certSync/certs
    url: https://certs
    key: /etc/certSync/<host>.key
    cert: /etc/certSync/<host>.crt
    domains:
      - name: <certificate domain name 1>
        files:
          - name: <cert file 1>
          - name: <cert file 2>
        scripts:
          - <post update script name 1>
          - <post update script name 2>
      - name: <certificate domain name 2>
        files:
          - name: <cert file 1>
          - name: <cert file 2>
        scripts:
          - <post update script name 1>
          - <post update script name 2>
  - name: letsencrypt-dir-sync
    type: directory
    source-dir: /opt/letsencrypt/etc/letsencrypt/live
    target-dir: /etc/ssl
    domains:
      - name <certificate domain name 1>
        files:
          - name: <cert file 1>
          - name: <cert file 2>
        scripts:
          - <post update script name 1>
          - <post update script name 2>
      - name <certificate domain name 2>
        files:
          - name: <cert file 1>
          - name: <cert file 2>
        scripts:
          - <post update script name 1>
          - <post update script name 2>
```

This maintains the structure of a directory to store the certs with a sub-directory for each domain (I use client-auth to store the mTLS files). I typically download at least the cert.pem and privkey.pem files.

The optional mode propery ensures that the script will lock down the file, this is typically used for the private key.

The script (or scripts) you configure can then take the appropriate action to implement the updated certificates. They are only triggered when certSync detects a change to a certificate. My scripts typically restart a docker container, copy files, convert files, etc.

An example: I use a Let's Encrypt certificate for my Octoprint setup. The script I use for that certificate concatenates the fullchain.pem and privkey.pem files from Let's Encrypt into /etc/ssl/snakeoil.pem and then restarts HA proxy to make it take effect.
