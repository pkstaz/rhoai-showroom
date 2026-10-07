# Imagen del plugin de consola opencode-agents: sirve el dist/ pre-compilado
# (npm run build en la raiz de console-plugin/opencode-agents).
FROM registry.access.redhat.com/ubi9/nginx-120:latest

COPY dist /usr/share/nginx/html
USER 1001

ENTRYPOINT ["nginx", "-g", "daemon off;"]
