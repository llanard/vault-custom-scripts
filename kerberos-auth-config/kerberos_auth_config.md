# Kerberos Authentication Vault configuration

Documentation basée sur ce tutoriel : https://support.hashicorp.com/hc/en-us/articles/20595942865939-How-to-authenticate-to-Vault-using-Kerberos-via-Active-Directory

## Pré-requis
- 1 VM Active Directory
- 1 VM linux vault server host


## Configurations sur l'AD
1. Configurer l'AD avec AD DS, DNS et CS

AD DS (LANARD.LOCAL)
créer 3 user : kerberos, ldap et louis

AD CS 
Copier le template "kerberos authentification" et nommer le LDAPS
Suivre ce tutoriel : https://www.youtube.com/watch?v=DCkzr8DslkY 

2. Créer les keytab sur l'AD pour kerberos et louis en respectant le kvno, puis scp sur serveur linux Vault

Afficher le kvno : 
```bash
Get-ADUser kerberos -property msDS-KeyVersionNumber
Get-ADUser louis -property msDS-KeyVersionNumber
```

Générer le keytab puis scp sur le serveur linux 
```bash
ktpass /princ kerberos@LANARD.LOCAL /crypto AES256-SHA1 /ptype KRB5_NT_PRINCIPAL  /kvno 6 /pass "ComplexP@ssw0rd123" /out krb.keytab
ktpass /princ louis@LANARD.LOCAL /crypto AES256-SHA1 /ptype KRB5_NT_PRINCIPAL  /kvno 5 /pass "ComplexP@ssw0rd123" /out louis.keytab
```

3. set le service puis vérifier
```bash
setspn -U -S HTTP/vault.lanard.local kerberos
setspn -L kerberos
```

## Configurations sur Vault (linux)

4. Ajouter le certificat LDAPS aux trusted certs sur le server linux.

5. Run Vault community or enterprise
```bash
vault server -config=/etc/vault.d/vault.hcl
```

6. Créer et configurer l'authentification kerberos
```bash
vault auth enable -passthrough-request-headers=Authorization -allowed-response-headers=www-authenticate kerberos
```

7. Configurer la config ldap sans ajouter les paramètres de groupes (groupattr, groupdn et groupfilter) dans un premier temps :
```bash
vault write auth/kerberos/config/ldap binddn="ldap@lanard.local" bindpass="ComplexP@ssw0rd123" userdn="CN=Users,DC=lanard,DC=local" userattr="sAMAccountName" url="ldaps://<AD_IP>:636" upndomain="LANARD.LOCAL" insecure_skip_verify=true  insecure_tls=true
```

8. Créer le fichier krb5.conf
```bash
[libdefaults]
default_realm = LANARD.LOCAL
dns_lookup_realm = false
dns_lookup_kdc = true
  ticket_lifetime = 24h
  renew_lifetime = 7d
  forwardable = true
  rdns = false
preferred_preauth_types = 18
[realms]
LANARD.LOCAL = {
  kdc = AD_IP
  admin_server = AD_IP
  master_kdc = AD_IP
  default_domain = AD_IP
}
```

8. S'authentifier
```bash
vault login -method=kerberos username=louis service=HTTP/vault.lanard.local realm=LANARD.LOCAL keytab_path=louis.keytab krb5conf_path=./krb5.conf disable_fast_negotiation=true
```
-> Vous devez recevoir un token Vault.


Troubleshooting
1. erreur vide
Error authenticating: Error making API request.

URL: PUT http://172.31.33.217:8200/v1/auth/kerberos/login
Code: 400. Errors:


$
-> le problème vient du keytab kerberos

2. Erreur : *No Such Object*
* unable to get ldap groups: LDAP search failed: LDAP Result Code 32 "No Such Object": 0000208D: NameErr: DSID-0310028F, problem 2001 (NO_OBJECT), data 0, best match of:
	'DC=lanard,DC=local'
Problème de config LDAP, tentez de supprimer les paramètres de group
```bash
vault write auth/kerberos/config/ldap binddn="ldap@lanard.local" bindpass="ComplexP@ssw0rd123" userdn="CN=Users,DC=lanard,DC=local" userattr="sAMAccountName" url="ldaps://<AD_IP>:636" upndomain="LANARD.LOCAL" insecure_skip_verify=true  insecure_tls=true
```
Test LDAPS connection, credentials and arborescence : 
```bash
ldapsearch -x -LLL -H ldaps://lanard.local:636 -D "cn=louis,cn=Users,dc=lanard,dc=local" -w "ComplexP@ssw0rd123" -b "dc=lanard,dc=local" "(objectClass=person)" -ZZ cn mail
```

3. Erreur : *"Strong Auth Required"*
* LDAP bind failed: LDAP Result Code 8 "Strong Auth Required": 00002028: LdapErr: DSID-0C09035C, comment: The server requires binds to turn on integrity checking if SSL\TLS are not already active on the connection, data 0, v65f4
-> LDAP n'est pas accepté, il faut configurer LDAPS sur l'AD.

Test AD ports :
```bash
nmap -p 389,636,88,53 <AD_IP>
```

Test LDAPS connection, credentials and arborescence : 
```bash
ldapsearch -x -LLL -H ldaps://lanard.local:636 -D "cn=louis,cn=Users,dc=lanard,dc=local" -w "ComplexP@ssw0rd123" -b "dc=lanard,dc=local" "(objectClass=person)" -ZZ cn mail
```

4. Erreur : *"Invalid Credentials"*
* LDAP bind failed: LDAP Result Code 49 "Invalid Credentials": 80090308: LdapErr: DSID-0C090549, comment: AcceptSecurityContext error, data 52e, v65f4
-> Cela signifie que le mot de passe de l'un des comptes est faux, sûrement celui de ldap@lanard.local.