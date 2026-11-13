import 'package:flutter_test/flutter_test.dart';
import 'package:technician_portal/admin/features/modules/utility_screens.dart';

void main() {
  test('Device Mapping names: exact key, else the same short name; unmapped stay readable', () {
    final keys = ['FAHU-03/off_coil_temp', 'FAHU-03/CHW_VLV_FB', 'FAHU-03/RunStatus'];
    final labels = mappedLabels(keys, [
      {'pointKey': 'FAHU-03/off_coil_temp', 'displayName': 'Supply Air Temperature'},
      {'pointKey': 'GW-1/CHW_VLV_FB', 'displayName': 'Chilled Water Valve Position'},
      {'pointKey': 'FAHU-03/missing', 'displayName': 'Nope'},
    ]);
    expect(labels, {
      'FAHU-03/off_coil_temp': 'Supply Air Temperature',
      'FAHU-03/CHW_VLV_FB': 'Chilled Water Valve Position',
    });
    final d = MscDevice(id: '1', name: 'FAHU-03', tag: 'AHU', labels: labels);
    expect(d.labelOf('FAHU-03/off_coil_temp'), 'Supply Air Temperature');
    expect(d.labelOf('FAHU-03/RunStatus'), 'Run status');
  });
}
