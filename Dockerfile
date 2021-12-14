# Build stage 0
FROM erlang:22

# Install some libs
RUN apt-get update -y && apt-get install -y \
      libstdc++6 openssl libtinfo5 

# Set working directory
WORKDIR /opt/thepower

RUN mkdir -p /opt/thepower/db

# Copy Power_node application
COPY . .

# Set symlink
RUN ln -s /usr/bin/openssl /usr/local/bin/openssl

# Expose relevant ports
EXPOSE 49841
EXPOSE 29841

ENTRYPOINT [ "./bin/thepower" ] 

CMD ["foreground"]