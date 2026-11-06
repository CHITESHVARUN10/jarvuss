"""Optional intent-token weighting; model architecture and serving stay unchanged."""
import json
import re


def intent_weights(target, offsets, known, weight,typed=False):
    spans=[];stack=[];current=None
    # Track JSON depth so an argument named "name" is not mistaken for the
    # enclosing intent name. Escaped quoted JSON inside ai.query stays a string.
    for match in re.finditer(r'"(?:\\.|[^"\\])*"|[{}\[\]]',target):
        token=match.group()
        if token in ('{','['):stack.append(token)
        elif token in ('}',']'):stack.pop()
        else:
            key=json.loads(token)
            value=re.match(r'\s*:\s*("(?:\\.|[^"\\])*"|-?\d+)',target[match.end():])
            if not value:continue
            decoded=json.loads(value[1]);mark=False
            if stack==['[','{'] and key=='name' and decoded in known:
                current=decoded;mark=True
            elif typed and stack==['[','{','{'] and isinstance(known,dict) and current in known:
                spec=known[current]
                mark=(key in spec.get('enums',{}) and decoded in spec['enums'][key]) or (spec.get('types',{}).get(key)=='int' and type(decoded) is int)
            if mark:
                quoted=value[1].startswith('"');start=match.end()+value.start(1)+int(quoted)
                spans.append((start,match.end()+value.end(1)-int(quoted)))
    return [float(weight) if end>start and any(start<b and end>a for a,b in spans) else 1.
            for start,end in offsets]


def weighted_cross_entropy(logits,labels,weights):
    import torch.nn.functional as F
    loss=F.cross_entropy(logits.reshape(-1,logits.shape[-1]),labels.reshape(-1),ignore_index=-100,reduction='none')
    active=weights.reshape(-1)*(labels.reshape(-1)!=-100)
    return (loss*active).sum()/active.sum().clamp_min(1)


def grouped_cross_entropy(logits,labels,weights,intent_weight):
    """Balance the two tasks per example, independent of argument length."""
    import torch.nn.functional as F
    loss=F.cross_entropy(logits.reshape(-1,logits.shape[-1]),labels.reshape(-1),ignore_index=-100,reduction='none').reshape(labels.shape)
    active=labels!=-100;names=active & (weights>1);arguments=active & ~names
    name_loss=(loss*names).sum(-1)/names.sum(-1).clamp_min(1)
    argument_loss=(loss*arguments).sum(-1)/arguments.sum(-1).clamp_min(1)
    return ((intent_weight*name_loss+argument_loss)/(intent_weight+1)).mean()


def weighted_collator(base,tokenizer):
    def collate(features):
        import torch
        copies=[dict(f) for f in features]
        weights=[f.pop('loss_weights') for f in copies]
        batch=base(copies);length=batch['labels'].shape[1]
        padded=[w+[0.]*(length-len(w)) if tokenizer.padding_side=='right' else [0.]*(length-len(w))+w for w in weights]
        batch['loss_weights']=torch.tensor(padded,dtype=torch.float32)
        return batch
    return collate


def trainer_type(mode='token',intent_weight=3.):
    from transformers import Seq2SeqTrainer
    class IntentWeightedTrainer(Seq2SeqTrainer):
        def compute_loss(self,model,inputs,return_outputs=False,num_items_in_batch=None):
            weights=inputs.pop('loss_weights',None)
            if weights is None:
                return super().compute_loss(model,inputs,return_outputs=return_outputs,num_items_in_batch=num_items_in_batch)
            outputs=model(**inputs)
            loss=(grouped_cross_entropy(outputs.logits,inputs['labels'],weights,intent_weight) if mode=='grouped'
                  else weighted_cross_entropy(outputs.logits,inputs['labels'],weights))
            return (loss,outputs) if return_outputs else loss

        def prediction_step(self,model,inputs,prediction_loss_only,ignore_keys=None,**kwargs):
            # generate() must never receive this training-only tensor. Eval
            # loss remains ordinary CE; checkpoint choice uses exact matches.
            clean={k:v for k,v in inputs.items() if k!='loss_weights'}
            return super().prediction_step(model,clean,prediction_loss_only,ignore_keys=ignore_keys,**kwargs)
    return IntentWeightedTrainer
