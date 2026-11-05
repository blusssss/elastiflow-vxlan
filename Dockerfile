FROM robcowart/elastiflow-logstash:4.0.1

USER root
RUN echo '2cb511dbd0f49ebe5aef979859289190f2c4815db97b1f9b0c03070004c04a58  /usr/share/logstash/vendor/bundle/jruby/2.5.0/gems/logstash-codec-sflow-2.1.3/lib/logstash/codecs/sflow.rb' | sha256sum -c -

COPY plugin/lib/logstash/codecs/sflow.rb /usr/share/logstash/vendor/bundle/jruby/2.5.0/gems/logstash-codec-sflow-2.1.3/lib/logstash/codecs/sflow.rb
COPY plugin/lib/logstash/codecs/sflow/vxlan.rb /usr/share/logstash/vendor/bundle/jruby/2.5.0/gems/logstash-codec-sflow-2.1.3/lib/logstash/codecs/sflow/vxlan.rb
RUN chown logstash:root /usr/share/logstash/vendor/bundle/jruby/2.5.0/gems/logstash-codec-sflow-2.1.3/lib/logstash/codecs/sflow.rb /usr/share/logstash/vendor/bundle/jruby/2.5.0/gems/logstash-codec-sflow-2.1.3/lib/logstash/codecs/sflow/vxlan.rb

COPY build/elastiflow.template.json /etc/logstash/elastiflow/templates/elastiflow.template.json
COPY assets/ /opt/elastiflow-deploy/
RUN cp /etc/logstash/elastiflow/templates/elastiflow.template.json /opt/elastiflow-deploy/elastiflow.template.json

USER logstash
