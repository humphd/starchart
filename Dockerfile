FROM node:18-bullseye-slim@sha256:e2fbe082615911b184e192b05c55e7e38460a2c24c88d92e8c122ea0175fbe56 as base

ARG CURL_VERSION=7.74.* \
  OPENSSL_VERSION=1.1.* \
  TINI_VERSION=0.19.* \
  # Specify the XML file to use for configuring the SAML IDP (see config/idp-metadata-*.xml)
  SAML_IDP_METADATA_PATH=config/idp-metadata-dev.xml
  
# hadolint ignore=SC2086
RUN apt-get update && \
  apt-get install -y --no-install-recommends \
  curl=${CURL_VERSION} \
  openssl=${OPENSSL_VERSION} \
  tini=${TINI_VERSION} \
  && rm -rf /var/lib/apt/lists/*

###############################################################################

# Install all node_modules, including dev dependencies
FROM base as deps

WORKDIR /app
COPY package*.json .npmrc ./
RUN npm ci --include=dev --ignore-scripts

###############################################################################

# Remove any non-production dependencies
FROM base as production-deps

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY package*.json .npmrc ./
RUN npm prune --omit=dev

###############################################################################

# Build the app and generate the prisma client
FROM base as build

WORKDIR /app
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npx prisma generate \
  && npm run build

###############################################################################

# Deploy the built app on top of the production deps, run as non-root
FROM base as deploy

WORKDIR /app
ENV NODE_ENV=production \
    PORT=8080 \
    LOG_LEVEL=info

USER node
COPY --chown=node:node --from=production-deps /app/node_modules ./node_modules
COPY --chown=node:node --from=build /app/node_modules/.prisma ./node_modules/.prisma
COPY --chown=node:node --from=build /app/build ./build
COPY --chown=node:node --from=build /app/public ./public

# Include the SAML IDP metadata in the image. Specify the file to use in the build arg
# and override the SAML_IDP_METADATA_PATH to use when loading this file at startup
COPY --chown=node:node ${SAML_IDP_METADATA_PATH} ./config/idp-metadata.xml
ENV SAML_IDP_METADATA_PATH=/app/build/config/idp-metadata.xml

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["node", "./build/server.js"]

HEALTHCHECK CMD curl --fail http://localhost:${PORT}/healthcheck || exit 1
EXPOSE ${PORT}
