FROM ghcr.io/quarto-dev/quarto:1.9.37 AS build
COPY . /site
WORKDIR /site
RUN quarto render --output-dir /site

FROM nginx:alpine
COPY site/ /usr/share/nginx/html
EXPOSE 80