class WebinarPCMCollector extends AudioWorkletProcessor {
      constructor() {
        super(); this.samples=new Float32Array(4096); this.used=0; this.sequence=0; this.active=true;
        this.port.onmessage=event=>{if(event.data?.stop)this.active=false;};
      }
      process(inputs, outputs) {
        if(!this.active)return false;
        const channels=inputs[0];
        const frames=outputs[0]?.[0]?.length || channels?.[0]?.length || 128;
        for(let i=0;i<frames;i++) {
          let value=0;
          if(channels?.length)for(const channel of channels)value+=(channel[i] || 0)/channels.length;
          this.samples[this.used++]=value;
          if(this.used===this.samples.length) {
            const samples=this.samples;
            this.port.postMessage({samples,sequence:this.sequence++,frameEnd:currentFrame+i+1},[samples.buffer]);
            this.samples=new Float32Array(4096); this.used=0;
          }
        }
        return true;
      }
    }
    registerProcessor('webinar-pcm-collector',WebinarPCMCollector);
