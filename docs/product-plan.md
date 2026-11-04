# Plan aprobado del MVP para una concesionaria

Estado: aprobado en conversación el 2026-11-02. Este documento no implica que la aplicación esté implementada.
Objetivo: operar con una concesionaria, validando el flujo comercial completo y manteniendo la posibilidad de evolucionar a varias.

## 1. Alcance y stack

- Sitio público y panel privado como dos aplicaciones Next.js con TypeScript estricto, en un repositorio compartido y con despliegues separados.
- Direcciones gratuitas de los proveedores; sin dominio propio en el MVP.
- Tailwind CSS, shadcn/ui, React Hook Form, Zod, TanStack Query y Recharts.
- Supabase para PostgreSQL, autenticación y almacenamiento de imágenes.
- Cloudflare como alojamiento provisional, sujeto a prueba temprana de compatibilidad y costo cero.
- shadcn/ui simplifica la primera versión; puede personalizarse, reducirse o reemplazarse posteriormente. No se promete reemplazo sin trabajo.
- Sin plataforma multiagencia en esta versión; configuración e identidad desacopladas de la lógica comercial.

## 2. Roles y accesos

| Rol | Permisos |
|---|---|
| Dueño | Gestión completa, incluida la gestión de administradores |
| Administrador | Los mismos permisos operativos que Dueño, salvo gestionar administradores |
| Vendedor | Gestión de consultas asignadas, seguimiento, visitas y estadísticas autorizadas; reserva acotada desde una consulta propia, sin edición general del inventario |

- Acceso por invitación, e-mail y contraseña, con recuperación; sin registro público.
- El primer Dueño se aprovisiona mediante un script específico ejecutado manualmente desde un entorno confiable, no por registro público. Aprobar este mecanismo no autoriza crear cuentas ni ejecutarlo remotamente.
- Si el alta de identidad se completa pero falla el perfil del primer Dueño, una nueva ejecución controlada verifica que sea la identidad prevista y completa el perfil solo si aún no existe un Dueño activo. No borra automáticamente la identidad.
- Dueño incorpora administradores; Dueño y Administrador incorporan vendedores.
- Los vendedores pueden consultar todos los vehículos y sus precios internos en el panel, sin permiso de edición general. No se limita la lectura a vehículos publicados ni a sus consultas.
- Desactivar usuarios conserva historial y revoca de inmediato el acceso operativo. Vendedores inactivos salen del reparto; sus consultas abiertas quedan pendientes de reasignación. Si una consulta sostiene una reserva activa, la desactivación no libera el vehículo: Dueño/Administrador debe resolver primero la reserva antes de reasignarla.
- No se puede desactivar ni quitar el rol al último Dueño activo; el backend debe impedirlo incluso ante cambios simultáneos de usuarios.

## 3. Inventario y catálogo

- Autos y motos con campos específicos por tipo.
- No se asignan vehículos a vendedores. Crear, publicar, editar, marcar vendido y archivar vehículos corresponde únicamente a Dueño y Administrador. Como excepción acotada, un vendedor puede reservar un vehículo disponible desde una consulta activa propia; no puede reservarlo desde la ficha ni desde consultas ajenas.
- Todos los vendedores activos son elegibles para recibir consultas de cualquier vehículo; no hay asignaciones ni exclusiones de vendedores por vehículo en el MVP. Dueño y Administrador solo participan del reparto cuando se habilita individualmente su participación comercial para el vehículo.
- Al crear un vehículo, una opción permite seleccionar personas concretas de rol Dueño o Administrador para atender sus consultas, sin ninguna preseleccionada. Los administrativos habilitados y activos participan del mismo round robin, no como respaldo. No se habilita automáticamente a todo un rol.
- Dueño y Administrador pueden quitar posteriormente la habilitación comercial de una persona Dueño/Administrador para un vehículo. Deja de recibir nuevas consultas de ese vehículo, incluso por continuidad, pero conserva las consultas existentes y su acceso hasta reasignación explícita. No cambia su rol administrativo.
- Dueño y Administrador también pueden habilitar después de crear el vehículo a una persona Dueño/Administrador para recibir nuevas consultas de ese vehículo; no se le trasladan automáticamente consultas existentes.
- Cada consulta se asigna a un responsable. Un vehículo puede tener múltiples consultas atendidas por distintos vendedores elegibles, sin exigir que cada consulta tenga un vendedor diferente.
- Dueño y Administrador pueden reasignar consultas conservando historial.
- El Administrador puede quitar una consulta ya asignada a cualquier responsable, incluido otro Dueño/Administrador, y pasarla expresamente a otra persona; esto cambia al responsable comercial, no el rol ni los permisos administrativos globales del anterior.
- Toda reasignación manual debe respetar la elegibilidad vigente del nuevo responsable: vendedor activo, o Dueño/Administrador activo y habilitado individualmente para el vehículo que originó la consulta. Si no es elegible, se bloquea; la desactivación no retira por sí sola la atribución histórica.
- Una consulta vinculada a una reserva activa no se reasigna mientras siga reservada: primero se cancela la reserva o Dueño/Administrador resuelve la venta. Cancelada la reserva, la consulta activa se puede reasignar siguiendo las reglas normales; una consulta cerrada requiere reapertura autorizada.
- Al reasignar, el vendedor anterior pierde acceso al detalle de la consulta, pero conserva atribución de sus actividades en estadísticas históricas. Los reportes no deben devolverle acceso al detalle; Dueño y Administrador conservan visión global.
- Publicación: Borrador o Publicado. Disponibilidad independiente: Disponible, Reservado o Vendido.
- Borradores y sus imágenes no son públicos.
- Reservados permanecen visibles con etiqueta y admiten consultas y solicitudes de visita, avisando que están sujetos a disponibilidad.
- Vendidos salen del catálogo y conservan su ficha informativa si estaban publicados, sin solicitud de visita ni contacto directo.
- Desde vendidos, “Ver vehículos similares” abre una búsqueda editable por tipo de vehículo y categoría de auto/moto. No exige marca/modelo iguales ni crea una consulta.
- Baja lógica en el MVP; borrado definitivo y conservación estadística se diseñarán en otra etapa.
- Dueño y Administrador pueden bloquear o habilitar un vehículo para la venta. El bloqueo interno es distinto de una reserva comercial y no cuenta como tal. Se rechaza bloquear un vehículo con reserva activa: primero debe resolverse explícitamente la reserva, sin cancelación automática. Un vehículo bloqueado no se muestra en el sitio público; conserva información e historial en el panel privado.
- Filtros: tipo de vehículo, marca, modelo, año, precio, kilometraje, transmisión manual/automática, tipo de auto, tipo de moto y cilindrada para motos.
- Orden por precio o publicaciones recientes. Las categorías concretas y campos completos se especificarán antes de inventario.

## 4. Precios e imágenes

- Precio interno obligatorio, visible para vendedores en todos los vehículos y editable únicamente por Dueño y Administrador. “Consultar precio” solo oculta el importe al público, no a los vendedores.
- Precio base ARS o USD. Equivalente calculado con cotización de la concesionaria, editable por Dueño y Administrador con historial.
- Presentación pública por vehículo: pesos, dólares, ambas monedas o “Consultar precio”.
- Precios ocultos no se exponen en interfaces públicas. Esos vehículos se excluyen al filtrar por rango y van al final al ordenar por precio.
- Hasta 12 fotos por vehículo, portada y orden configurables.
- Compresión automática en navegador, sin modificar el original local ni recortar/deformar, con vista previa y validación posterior en servidor.
- Referencia inicial: hasta 1920 píxeles del lado mayor y 1 MB por foto resultante, ajustable tras pruebas reales. El máximo de entrada requiere definición.
- Procesamiento de fotos de a una y error claro si no puede alcanzarse un resultado aceptable.
- Compresión en navegador es una decisión revisable. No se asume compatibilidad con todo formato de cámara.

## 5. Consultas y reparto

- Formulario obligatorio antes de WhatsApp: nombre, teléfono y e-mail, validados en cliente y backend, sin verificar titularidad.
- Una consulta es una entrada de seguimiento comercial, con origen web, presencial o telefónico. Vendedor, Administrador y Dueño pueden registrar consultas manuales; quedan asignadas a quien las registra, sin utilizar ni avanzar el reparto automático web. La carga manual exige nombre y teléfono; el e-mail es opcional. Puede utilizar un contacto existente o crear uno nuevo, sin sobrescribir automáticamente datos previos ni habilitar acceso al historial ajeno por coincidencia de teléfono.
- Teléfonos internacionales admitidos, priorizando Argentina y evitando fricción innecesaria.
- Contacto reconocido por teléfono normalizado; una persona puede tener varias consultas con seguimiento independiente.
- Una consulta activa puede reunir varios vehículos de interés sin crear automáticamente nuevas consultas ni reservas; conserva un responsable comercial. El vendedor puede agregar vehículos de interés a sus propias consultas activas; al agregarlos deben estar disponibles en ese momento. Si luego otra consulta reserva uno, permanece registrado como interés, pero deja de estar disponible para reservarlo mientras dure esa reserva. Desde la consulta se puede reservar cualquier vehículo de interés que siga Disponible, aunque no sea el vehículo de origen; la reserva identifica consulta, contacto y vehículo concreto. Solo puede haber una reserva activa por consulta; para cambiar de vehículo se cancela primero la anterior y se conserva el historial. Cada visita identifica un vehículo concreto; la atribución comercial por vehículo se define en estadísticas.
- El MVP no admite contactos distintos con el mismo teléfono normalizado ni fusión de contactos. Dueño/Administrador pueden corregirlo por un número libre; si ya pertenece a otro contacto, se rechaza el cambio con aviso y sin alterar datos o consultas.
- Si un formulario trae un teléfono conocido con nombre o e-mail diferentes, se conservan los datos existentes del contacto y se guardan los enviados en la nueva consulta para revisión. Nunca se sobrescriben automáticamente por un envío público; siguen disponibles las correcciones manuales autorizadas.
- El vendedor puede corregir nombre y e-mail de contactos de sus consultas. Cambiar el teléfono corresponde únicamente a Dueño o Administrador. Editar datos del contacto no habilita acceso a consultas de otros vendedores; conflictos o coincidencias de teléfono requieren resolución explícita, no fusión automática.
- Cada intento de envío tiene un identificador aleatorio generado por el cliente y conservado con su consulta, sin vencimiento propio: un reintento reutiliza ese identificador y no crea duplicados; una consulta nueva usa otro. Reutilizarlo con datos distintos se rechaza. La respuesta repetida no expone datos privados. El cliente no elige vendedor.
- Continuidad: buscar consultas activas del contacto cuyo responsable esté activo y sea elegible para el vehículo de origen del nuevo envío: cualquier vendedor activo o Dueño/Administrador habilitado individualmente para ese vehículo. Conservar ese responsable; si hay varios, usar el de la consulta activa más reciente entre elegibles. Esta regla sigue teniendo prioridad sobre round robin.
- Si llegan dos envíos distintos casi al mismo tiempo para el mismo contacto, el segundo debe considerar la primera consulta ya creada y aplicar continuidad si su responsable es elegible para el segundo vehículo; no se reparten ambos como si el contacto todavía no tuviera consultas. Cada envío intencional conserva su propia consulta.
- Sin continuidad aplicable: un responsable elegible recibe la consulta; varios se reparten por el mismo round robin, sin prioridad por rol; ninguno deja la consulta pendiente para Dueño/Administrador y abre WhatsApp general.
- No se impone vendedor exclusivo por cliente entre todos los vehículos. Esa regla quedó pospuesta.
- Proteger el formulario público contra automatización y repetición. Reconocer teléfono no habilita a revelar historial ni identidad previa públicamente.

## 6. CRM, reservas y visitas

| Estado de consulta | Significado |
|---|---|
| Nuevo | Sin acción de contacto registrada |
| Contactado | Contacto o intento registrado; no exige respuesta |
| En seguimiento | Oportunidad abierta con seguimiento pendiente |
| Venta concretada | Venta reportada en la consulta, no solamente una reserva; la venta del vehículo requiere confirmación de Dueño/Administrador |
| Cerrada sin venta | Oportunidad finalizada sin venta |

- Activas: Nuevo, Contactado y En seguimiento. Abrir WhatsApp no cambia automáticamente a Contactado.
- Notas y tareas con vencimiento; pendientes y vencidas visibles en panel, sin recordatorios por correo/WhatsApp.
- Reportar Venta concretada exige identificar uno de los vehículos de interés de esa consulta; no requiere reserva previa si ese vehículo sigue Disponible. Si la consulta tiene una reserva activa, solo se puede reportar la venta del vehículo reservado. Se bloquea el reporte para un vehículo Reservado por otra consulta o ya Vendido. El reporte no cambia el inventario ni cierra otras consultas; la actualización a Vendido requiere confirmación separada de Dueño/Administrador.
- Si otro cliente reserva el vehículo después de que se reportó una venta sin reserva previa, Dueño/Administrador no puede confirmar Vendido para el primer cliente hasta resolver expresamente esa reserva. El reporte queda pendiente de revisión; no cancela ni desplaza automáticamente la reserva ajena.
- La consulta con reserva activa puede pasar a Venta concretada para iniciar revisión administrativa, pero no a Cerrada sin venta hasta cancelar la reserva. Cuando un vendedor reporta Venta concretada se crea una tarea pendiente para Dueño/Administrador. Si confirma la venta, finaliza la reserva y cambia expresamente el vehículo a Vendido; si determina que no hubo venta, cancela cualquier reserva activa y corrige la consulta a Cerrada sin venta. Ambos caminos resuelven la tarea, preservan historial y no cierran otras consultas.
- Si se confirma la venta de uno de varios vehículos de interés, esa consulta termina en Venta concretada para el vehículo vendido. Los demás intereses quedan en su historial; no generan ventas ni se cierran consultas de otras personas.
- El vendedor puede reabrir sus consultas Cerrada sin venta, conservando historial. Reabrir Venta concretada corresponde únicamente a Dueño o Administrador. Toda reapertura vuelve a En seguimiento y no cambia la disponibilidad del vehículo.
- Una consulta con revisión de venta pendiente no puede reabrirse: Dueño/Administrador debe confirmar o rechazar primero esa revisión. T5 no permite revertir ventas confirmadas; reabrir solo retoma el seguimiento y conserva el vehículo Vendido y el historial de venta.
- Toda venta exige una consulta vinculada y confirmación explícita de Dueño/Administrador, incluidas las ventas presenciales registradas manualmente. No se permite crear ni marcar un vehículo Vendido directamente desde inventario, evitando omitir el contacto y el historial comercial.
- El bloqueo interno impide reportar y confirmar una venta hasta que Dueño/Administrador desbloquee el vehículo explícitamente; se verifica tanto al reportar como al confirmar.
- No se reasignan consultas cerradas directamente. Si se retoma el seguimiento, primero se reabre según los permisos anteriores y después Dueño/Administrador puede reasignarla a una persona elegible, conservando historial.
- Solo puede existir una reserva activa por vehículo y una por consulta. Toda reserva comercial identifica obligatoriamente una consulta, su contacto y el vehículo concreto. Reservar desde una consulta activa propia exige que el vehículo figure entre sus intereses, siga Disponible y habilitado para la venta y la consulta no tenga otra reserva activa; cambia la disponibilidad a Reservado en una operación atómica. Intentos concurrentes de reservar el mismo vehículo o de crear una segunda reserva para la consulta se rechazan sin cambios parciales. Vendedor, Dueño y Administrador pueden registrar manualmente la consulta y continuar con la reserva; sin señas, pagos ni vencimiento automático.
- La reserva iniciada por vendedor siempre queda vinculada a su consulta. Ese vendedor puede cancelarla mientras la consulta siga asignada a él y la reserva continúe activa; la cancelación libera el vehículo a Disponible y conserva el historial. No puede cancelar reservas de otros. Dueño y Administrador también pueden cancelarlas. Ya no se admiten reservas comerciales sin consulta vinculada.
- Visita solicitada desde ficha con fecha/hora preferidas dentro del horario de atención; crea consulta con visita vinculada y usa el mismo reparto.
- Desde una consulta activa con varios vehículos de interés se puede solicitar una visita para uno de ellos: la visita registra ese vehículo y queda vinculada a la consulta existente, sin crear otra consulta ni reservar automáticamente el vehículo.
- Vendedor confirma o reprograma después de contactar. No hay reserva automática ni disponibilidad en tiempo real.

## 7. Estadísticas e identidad

- Medición propia y acotada de visualizaciones por ficha, no personas únicas.
- Consultas, clics de contacto, solicitudes/resultados de visita, reservas vinculadas y ventas se distinguen; no se suman como clientes diferentes.
- Cada consulta se cuenta una sola vez y se atribuye al vehículo de origen. Los demás vehículos vinculados se registran como intereses, no como nuevas consultas. Cada visita, reserva y venta confirmada se atribuye al vehículo concreto correspondiente; que una consulta tenga varios intereses no duplica oportunidades ni ventas.
- La venta se contabiliza al confirmar Dueño/Administrador el estado Vendido del vehículo, no cuando el vendedor marca la consulta como Venta concretada. Evitar contar dos veces la misma unidad; la atribución temporal y eventuales reversiones se definirán antes de construir estadísticas.
- Mostrar cantidades y relaciones entre vistas y objetivos, sin afirmar causalidad ni medir conversación recibida a partir de un clic de WhatsApp.
- Las vistas se cuentan por vehículo y no se duplican por vendedor elegible. Conservar atribución histórica de consultas y actividades.
- Dueño/Administrador: visión global y por vendedor. Vendedor: solamente información autorizada.
- Mes, trimestre, semestre, año y rango personalizado. Fórmulas y atribución temporal se definirán antes de construir los gráficos.
- Las métricas comerciales distinguen consultas web, presenciales y telefónicas. Las consultas manuales no se cuentan como conversiones del sitio; las relaciones exactas se definieron el 2026-11-04 (ver más abajo).
- Definiciones aprobadas para estadísticas (2026-11-04): la visualización es la carga correcta de la ficha pública de un vehículo, no su aparición en el catálogo; solo el sitio público genera vistas y el panel privado nunca. Cada ficha cuenta una vez cada 24 horas móviles por navegador mediante un token aleatorio opaco sin datos personales; no se verifica identidad de visitantes. El filtro de bots por User-Agent conocido es imperfecto, aceptado como acotado para el MVP y sin precisión forense.
- Atribución temporal: zona horaria fija `America/Argentina/Buenos_Aires` para todos los eventos; cortes a medianoche local para mes, trimestre, semestre y año; rangos personalizados inclusive por días en la misma zona.
- Atribución por responsable: las actividades se atribuyen a quien las realizó y no cambian con la reasignación; el resultado de la consulta (venta confirmada o cierre sin venta) se atribuye al responsable vigente al momento de registrarse el resultado.
- Cierres sin venta repetidos: cada cierre se cuenta como un evento de resultado, incluso si la consulta se reabrió y volvió a cerrarse. Cada evento se atribuye al responsable vigente al registrarse; reabrir no elimina cierres anteriores ni duplica el conteo de consultas.
- Historial de cierres: cuando no exista una atribución histórica fiable, mostrar «responsable desconocido», sin reconstruirla a partir del responsable actual ni del administrador que registró el cierre. Los nuevos cierres conservan al responsable vigente al registrarse.
- Relaciones y conversiones: mismos períodos para vistas y consultas web; relación por ficha = consultas web de origen en el vehículo ÷ vistas deduplicadas del vehículo; relación global = consultas web ÷ vistas totales del período. Se etiquetan como relación, nunca como causalidad. Las consultas manuales, presenciales y telefónicas se muestran como cantidades aparte y no entran en el numerador. Reservas, visitas y ventas confirmadas se muestran como cantidades absolutas.
- Visitas: la solicitud de visita se cuenta como evento propio atribuido al vehículo concreto de la visita, sin contarlo como consulta ni conversión. Por decisión aprobada, la implementación de esta métrica se difiere de T6 al flujo de visitas, cuando exista su fuente de datos; se conserva la definición de conteo. Resultados y cancelaciones se definirán junto con el flujo de visitas y permanecen pendientes.
- Acceso en estadísticas: el vendedor ve solo sus cifras (consultas donde fue responsable, resultados y actividades atribuidos, visitas/reservas/ventas atribuidas), nunca totales de la concesionaria, cifras de otros vendedores, comparaciones ni vistas por vehículo; en consultas reasignadas conserva la atribución histórica en sus cifras pero nunca el detalle. Dueño/Administrador ve visión global, por vehículo (incluidas vistas), por vendedor y comparaciones.
- Conteo de consultas por responsable: cada consulta se cuenta una sola vez por cada responsable distinto, en el período de su primera asignación a esa persona. Volver a asignársela no suma otro conteo. Ejemplo: Ana en enero, Bruno en febrero y Ana nuevamente en marzo produce un conteo para Ana en enero y uno para Bruno en febrero, sin otro para Ana en marzo. El total global sigue siendo una consulta; los conteos por responsable no se suman para obtenerlo.
- Consultas con historial de responsables incompleto: conservarlas en el total global y mostrarlas en un grupo separado como «historial de responsables incompleto», sin atribuirlas a períodos por persona mediante fechas no demostrables. Esta limitación del conteo de consultas no altera ventas o cierres con atribución fiable.
- Reversiones: la venta se cuenta una sola vez al confirmar Dueño/Administrador; el MVP no contempla reversiones de venta. Una futura reversión requerirá definición previa.
- Plantilla pública fija con nombre, logo, descripción, dirección, horarios, contactos, redes y colores configurables; sin editor visual.

## 8. Calidad, exclusiones y entrega

- Código y nombres técnicos en inglés; interfaz en español.
- Permisos backend, migraciones, integridad PostgreSQL, pruebas según riesgo, sin cobertura global porcentual obligatoria.
- Revisión de formato, lint, tipos, pruebas aplicables, compilación y UX móvil/escritorio, teclado y estados vacíos/carga/error.
- Excluidos: suscripciones, facturación, pagos, integración de conversaciones de WhatsApp y editor visual.
- Futuro: hard delete conservando estadísticas, evolución multiagencia, continuidad comercial ampliada y revisión visual/compresión.
- Orden: fundaciones y prueba de alojamiento → accesos/configuración → inventario → sitio público → consultas → CRM/visitas → estadísticas → piloto.
- Costo cero es una restricción del MVP, no una garantía de cuotas suficientes. No contratar servicios pagos sin acuerdo.

## 9. Pendientes de fundaciones

No están aprobadas soluciones técnicas concretas para estos puntos:

- Prueba de hosting gratuito y adaptador Next.js; almacenamiento y transferencia incluyendo imágenes archivadas.
- Entrega real de correos de invitación y recuperación con costo cero; creación inicial del Dueño.
- Esquema inicial, matriz definitiva de operaciones sensibles y mapa de pantallas.
- Desempates exactos de consultas con fechas idénticas.
- Cancelación/resultados de visitas, excepciones de estados y política de eliminación/retención futura.
- Límites de entrada de imágenes, tratamiento de logos, formatos soportados y normalización de teléfonos reales.

Resolver estos detalles proporcionalmente antes de implementar cada flujo; no inventar reglas comerciales para cerrar un pendiente.

## Historial de cambios aprobados

- 2026-11-04: Se difiere la implementación de la métrica de solicitudes de visita de T6 al flujo de visitas, sin alterar su definición aprobada ni diseñar anticipadamente dicho flujo.

- 2026-11-04: Se aprueban las definiciones de estadísticas para T6: visualización pública con deduplicación de 24 horas móviles por navegador, sin identidad de visitantes y con filtro de bots conocidos; atribución temporal fija en America/Argentina/Buenos_Aires; actividades atribuidas a su ejecutor y resultados al responsable vigente; relaciones de conversión web del mismo período sin causalidad; solicitudes de visita como evento propio con resultados pendientes del flujo de visitas; alcance del vendedor limitado a sus cifras; ventas contadas una sola vez al confirmar, sin reversiones. Se resuelven los pendientes de definición de visualización, tráfico, ventana temporal y denominadores; siguen abiertos resultados/cancelaciones de visitas y política de retención.

- 2026-11-03: Se incorpora al MVP la consulta como entrada común de seguimiento web, presencial o telefónico. Las consultas manuales se asignan a quien las registra, exigen nombre y teléfono y permiten omitir e-mail. Toda reserva comercial requiere consulta y contacto. Se incorpora bloqueo interno exclusivo de Dueño/Administrador, rechazado mientras exista reserva activa; un vehículo bloqueado no se muestra en el sitio público y conserva su historial privado. Estas decisiones reemplazan la exclusión de consultas externas y la reserva administrativa sin consulta.

- 2026-11-02: “Solo recibir consultas, el resto lo hace el admin o dueño únicamente. No asignemos autos, asignemos consultas. Es decir un auto puede tener muchas consultas y cada una va a un vendedor diferente, esto lógicamente si el vendedor no fue excluido.” Reemplaza la publicación directa, autoasignación y gestión de inventario por vendedores. Se conserva la continuidad de contacto previamente acordada, ahora basada en exclusiones.
- 2026-11-02: Para el MVP se eliminan también las exclusiones de vendedores por vehículo. Todos los vendedores activos pueden recibir consultas de cualquier vehículo; Dueño/Administrador continúan como participantes comerciales opcionales por persona y vehículo. Una consulta activa puede registrar varios vehículos de interés, sujeto a definir el detalle de reservas y atribución.
