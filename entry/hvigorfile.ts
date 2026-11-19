import fs from 'fs';
import path from 'path';
import { hvigor, HvigorNode, HvigorPlugin } from '@ohos/hvigor';
import { hapTasks } from '@ohos/hvigor-ohos-plugin';

function renameHapPlugin(): HvigorPlugin {
  return {
    pluginId: 'renameHapPlugin',
    apply(node: HvigorNode): void {
      hvigor.buildFinished(() => {
        const outDir = path.join(node.getNodePath(), 'build', 'default', 'outputs', 'default');
        const srcHap = path.join(outDir, 'entry-default-unsigned.hap');
        const dstHap = path.join(outDir, 'NoyACG-OHOS-unsigned.hap');
        if (fs.existsSync(srcHap)) {
          if (fs.existsSync(dstHap)) {
            fs.unlinkSync(dstHap);
          }
          fs.renameSync(srcHap, dstHap);
        }
      });
    }
  };
}

export default {
  system: hapTasks,
  plugins: [renameHapPlugin()]
}
