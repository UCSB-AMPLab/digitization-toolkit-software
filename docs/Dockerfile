FROM ghcr.io/quarto-dev/quarto:1.9.37 AS build
COPY . /site
WORKDIR /site
RUN quarto render --output-dir /output

FROM nginx:alpine
COPY --from=build /output /usr/share/nginx/html
EXPOSE 80