import importlib.util
import unittest
from intent_loss import intent_weights,weighted_cross_entropy,grouped_cross_entropy


class IntentLossTests(unittest.TestCase):
    def test_only_top_level_names_receive_extra_weight(self):
        target='[{"name":"app.open","args":{"name":"files.search"}}]'
        weights=intent_weights(target,[(n,n+1) for n in range(len(target))],{'app.open','files.search'},3.)
        start=target.index('app.open');arg=target.index('files.search')
        self.assertEqual(weights[start:start+8],[3.]*8)
        self.assertEqual(weights[arg:arg+12],[1.]*12)

    def test_typed_decisions_include_enum_and_integer_but_not_literal_names(self):
        from post_train import load_schema
        target='[{"name":"files.query","args":{"op":"count","folder":"downloads","ext":""}},{"name":"volume.set","args":{"level":19}}]'
        mask=intent_weights(target,[(n,n+1) for n in range(len(target))],load_schema(),3.,typed=True)
        for value in ('count','19'):
            start=target.index(value);self.assertEqual(mask[start:start+len(value)],[3.]*len(value))
        start=target.index('downloads');self.assertEqual(mask[start:start+9],[1.]*9)

    @unittest.skipUnless(importlib.util.find_spec('torch'),'training environment required')
    def test_intent_gradient_priority_and_ignored_padding(self):
        import torch
        logits=torch.zeros(1,3,2,requires_grad=True);labels=torch.tensor([[0,0,-100]])
        weighted_cross_entropy(logits,labels,torch.tensor([[4.,1.,0.]])).backward()
        self.assertAlmostEqual(float(logits.grad[0,0,0]/logits.grad[0,1,0]),4.)
        self.assertEqual(float(logits.grad[0,2].abs().sum()),0.)

    @unittest.skipUnless(importlib.util.find_spec('torch'),'training environment required')
    def test_default_weight_matches_standard_loss(self):
        import torch
        import torch.nn.functional as F
        logits=torch.tensor([[[1.,2.],[3.,1.],[1.,1.]]]);labels=torch.tensor([[1,0,-100]])
        self.assertTrue(torch.allclose(weighted_cross_entropy(logits,labels,torch.ones(1,3)),
                                       F.cross_entropy(logits.reshape(-1,2),labels.reshape(-1),ignore_index=-100)))

    @unittest.skipUnless(importlib.util.find_spec('torch'),'training environment required')
    def test_grouped_choice_signal_is_not_diluted_by_long_arguments(self):
        import torch
        gradients=[]
        for length in (2,20):
            logits=torch.zeros(1,length,2,requires_grad=True);labels=torch.zeros(1,length,dtype=torch.long)
            weights=torch.ones(1,length);weights[0,0]=3
            grouped_cross_entropy(logits,labels,weights,3.).backward()
            gradients.append(float(logits.grad[0,0,0]))
        self.assertAlmostEqual(gradients[0],gradients[1])


if __name__=='__main__':unittest.main()
