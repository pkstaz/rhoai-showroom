FROM registry.access.redhat.com/ubi9/nodejs-22:latest

USER root

ADD https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz /tmp/oc-client.tar.gz
RUN tar -xzf /tmp/oc-client.tar.gz -C /usr/local/bin oc kubectl \
    && chmod +x /usr/local/bin/oc /usr/local/bin/kubectl && rm -f /tmp/oc-client.tar.gz

ENV HOME=/tmp

WORKDIR /opt/app

RUN npm install opencode-ai@latest @mlflow/opencode@latest @mlflow/core@latest --no-audit --no-fund \
    && ./node_modules/.bin/opencode --version

EXPOSE 4096

CMD ["/opt/app/node_modules/.bin/opencode", "serve", "--hostname", "0.0.0.0", "--port", "4096", "--cors", "https://app.opencode.ai"]
