// [INPUT]: 系统 IOKit 温度服务；所有操作为只读。
// [OUTPUT]: 独立 PMU tdie 读取器，任何所选传感器丢失时明确返回失败。
// [POS]: 增强散热使用的稳定温度来源；不注册键盘或输入事件监听。
// [PROTOCOL]: 变更时更新此头部，然后检查 AGENTS.md
#ifndef VORSMATE_PMU_H
#define VORSMATE_PMU_H

typedef struct pmu_reader pmu_reader;
pmu_reader *pmu_create(void);
int pmu_read(pmu_reader *reader, double *temperature);
void pmu_destroy(pmu_reader *reader);

#endif
