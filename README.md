# certSync
Bash script to keep certificates in sync from a certificate auth enable central certificate server.

I manage certificates on my local network with a combination of a custom OpenSSL CA for client-auth and Let's Encrypt for everything else.

I wanted to way to manage the renewals across the various machines as some certificates are shared (I have a wildcard cert for my internal domain) and I didn't want to configure certbot everywhere.

I settled on have a single machine manaages all the Let's Encrypt certificates as well as own the client autentication OpenSSL CA and then expose those certificates (and keys) via Nginx.

However, to avoid the security issue of having private keys available to just anyone, I locked down the instance so the only authentication was via mTLS.

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

The certificates are hosted out of the /etc/docker-certs directory, with that directory I have a directory for each certificate that Let's Encrypt manages plus a client-auth directory which costs the internal OpenSSL certificate authority.

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

The /etc/docker-certs directory is mapped to /certs within the docker container and the ssl_client_certificate points to my OpenSSL CA.

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
Once the Nginx and OpenSSL setups are complete, I put certSync.sh in /opt/certSync and then create the /etc/certSync/ and /etc/certSync/scripts directories and finally copy the <server host name here>.key and <server host name here>.crt files to /etc/certSync.

I setup cron to run certSync.sh every day.

The configuration file, which I default to /etc/certSync/certSync.yml looks like this:
```
certificate-server-url: <ip or dns name for the Nginx server>
certificate-server-key: /etc/certSync/<server host name here>.key
certificate-server-cert: /etc/certSync/<server host name here>.crt
certificate-target-dir: /etc/certSync/certs
certs:
  - name: <the directory where this servers certificates are stored>
    files:
      - name: <cert file>
      - name: <key file>
        mode: 750
    scripts:
      - /etc/certSync/scripts/update-my-stuff.sh
```

Because I create a directory stucture under the /etc/docker-certs directory where there's a directory for each Let's Encrypt certificate domain that I have, I set the `name` to the certificate domain name. I typically download the cert.pem and privkey.pem files. The mode propery ensures that the script will lock down the private key.

The script (or scripts) you configure can then take the appropriate action to implement the updated certificates. They are only triggered when certSync detects a change to a certificate. This typically involves restarting a docker container, copying files, converting files, etc.

For example, I use a Let's Encrypt certificate for my Octoprint setup. The script I use for that certificate concatenates the fullchain.pem and privkey.pem files from Let's Encrypt into /etc/ssl/snakeoil.pem and then restart HA proxy to make it take effect.
