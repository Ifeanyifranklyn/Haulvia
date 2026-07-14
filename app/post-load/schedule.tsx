import DateTimePicker, {
    DateTimePickerEvent,
} from '@react-native-community/datetimepicker';
import { router, useLocalSearchParams } from 'expo-router';
import { useMemo, useState } from 'react';
import {
    Platform,
    Pressable,
    SafeAreaView,
    ScrollView,
    StyleSheet,
    Text,
    View,
} from 'react-native';

const PICKUP_WINDOWS = [
  {
    value: 'morning',
    label: 'Morning',
    detail: '8:00 AM\u201312:00 PM',
  },
  {
    value: 'afternoon',
    label: 'Afternoon',
    detail: '12:00 PM\u20135:00 PM',
  },
  {
    value: 'evening',
    label: 'Evening',
    detail: '5:00 PM\u20139:00 PM',
  },
  {
    value: 'flexible',
    label: 'Flexible',
    detail: 'Driver can coordinate the time',
  },
] as const;

const DELIVERY_OPTIONS = [
  {
    value: 'same-day',
    label: 'Same day',
    detail: 'Deliver on the pickup date',
  },
  {
    value: 'next-day',
    label: 'Next day',
    detail: 'Deliver one day after pickup',
  },
  {
    value: 'scheduled',
    label: 'Schedule a date',
    detail: 'Choose a specific delivery date',
  },
  {
    value: 'flexible',
    label: 'Flexible',
    detail: 'Let the driver coordinate delivery',
  },
] as const;

type PickupDateMode = 'today' | 'tomorrow' | 'custom';
type PickupWindow = (typeof PICKUP_WINDOWS)[number]['value'];
type DeliveryPreference = (typeof DELIVERY_OPTIONS)[number]['value'];

type LoadDetailsPayload = {
  pickupLocation?: string;
  deliveryLocation?: string;
  description: string;
  category: string | null;
  quantity: number;
  weight: number | null;
  weightUnit: 'lb' | 'kg';
  dimensions: {
    length: number;
    width: number;
    height: number;
    unit: 'in' | 'cm';
  } | null;
  vehicleRequirement: string | null;
  specialInstructions: string | null;
};

function startOfDay(date: Date) {
  const normalizedDate = new Date(date);
  normalizedDate.setHours(0, 0, 0, 0);
  return normalizedDate;
}

function addDays(date: Date, days: number) {
  const result = new Date(date);
  result.setDate(result.getDate() + days);
  return startOfDay(result);
}

function formatIsoDate(date: Date) {
  const year = date.getFullYear();
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');

  return `${year}-${month}-${day}`;
}

function formatDisplayDate(date: Date) {
  return date.toLocaleDateString(undefined, {
    weekday: 'short',
    year: 'numeric',
    month: 'short',
    day: 'numeric',
  });
}

export default function ScheduleScreen() {
  const params = useLocalSearchParams<{
    loadDetails?: string;
  }>();

  const todayDate = useMemo(() => startOfDay(new Date()), []);
  const tomorrowDate = useMemo(
    () => addDays(todayDate, 1),
    [todayDate],
  );

  const loadDetails = useMemo<LoadDetailsPayload | null>(() => {
    const rawValue = Array.isArray(params.loadDetails)
      ? params.loadDetails[0]
      : params.loadDetails;

    if (!rawValue) {
      return null;
    }

    try {
      return JSON.parse(rawValue) as LoadDetailsPayload;
    } catch {
      return null;
    }
  }, [params.loadDetails]);

  const [pickupDateMode, setPickupDateMode] =
    useState<PickupDateMode>('today');
  const [selectedPickupDate, setSelectedPickupDate] =
    useState<Date>(todayDate);
  const [showPickupDatePicker, setShowPickupDatePicker] =
    useState(false);

  const [pickupWindow, setPickupWindow] =
    useState<PickupWindow | null>(null);

  const [deliveryPreference, setDeliveryPreference] =
    useState<DeliveryPreference | null>(null);
  const [customDeliveryDate, setCustomDeliveryDate] =
    useState<Date | null>(null);
  const [showDeliveryDatePicker, setShowDeliveryDatePicker] =
    useState(false);

  const [showErrors, setShowErrors] = useState(false);

  const pickupDateValue =
    pickupDateMode === 'today'
      ? todayDate
      : pickupDateMode === 'tomorrow'
        ? tomorrowDate
        : selectedPickupDate;

  const pickupDate = formatIsoDate(pickupDateValue);
  const pickupDateIsValid =
    pickupDateValue.getTime() >= todayDate.getTime();

  const pickupWindowIsValid = pickupWindow !== null;
  const deliveryPreferenceIsValid = deliveryPreference !== null;

  const scheduledDeliveryDateIsValid =
    deliveryPreference !== 'scheduled' ||
    customDeliveryDate !== null;

  const scheduledDeliveryIsNotBeforePickup =
    deliveryPreference !== 'scheduled' ||
    customDeliveryDate === null ||
    customDeliveryDate.getTime() >= pickupDateValue.getTime();

  let deliveryDate: string | null = null;

  if (deliveryPreference === 'same-day') {
    deliveryDate = pickupDate;
  }

  if (deliveryPreference === 'next-day') {
    deliveryDate = formatIsoDate(addDays(pickupDateValue, 1));
  }

  if (
    deliveryPreference === 'scheduled' &&
    customDeliveryDate
  ) {
    deliveryDate = formatIsoDate(customDeliveryDate);
  }

  const formIsValid =
    loadDetails !== null &&
    pickupDateIsValid &&
    pickupWindowIsValid &&
    deliveryPreferenceIsValid &&
    scheduledDeliveryDateIsValid &&
    scheduledDeliveryIsNotBeforePickup;

  const applyPickupDate = (
    nextDate: Date,
    mode: PickupDateMode,
  ) => {
    const normalizedDate = startOfDay(nextDate);

    if (normalizedDate.getTime() < todayDate.getTime()) {
      return;
    }

    setPickupDateMode(mode);
    setSelectedPickupDate(normalizedDate);

    if (
      customDeliveryDate &&
      customDeliveryDate.getTime() < normalizedDate.getTime()
    ) {
      setCustomDeliveryDate(null);
    }
  };

  const handlePickupDateChange = (
    event: DateTimePickerEvent,
    date?: Date,
  ) => {
    if (Platform.OS === 'android') {
      setShowPickupDatePicker(false);
    }

    if (event.type === 'dismissed' || !date) {
      return;
    }

    applyPickupDate(date, 'custom');
  };

  const handleDeliveryDateChange = (
    event: DateTimePickerEvent,
    date?: Date,
  ) => {
    if (Platform.OS === 'android') {
      setShowDeliveryDatePicker(false);
    }

    if (event.type === 'dismissed' || !date) {
      return;
    }

    const normalizedDate = startOfDay(date);

    if (
      normalizedDate.getTime() < pickupDateValue.getTime()
    ) {
      return;
    }

    setCustomDeliveryDate(normalizedDate);
  };

  const handleDeliveryPreferenceChange = (
    preference: DeliveryPreference,
  ) => {
    setDeliveryPreference(preference);

    if (preference !== 'scheduled') {
      setShowDeliveryDatePicker(false);
      return;
    }

    if (
      !customDeliveryDate ||
      customDeliveryDate.getTime() < pickupDateValue.getTime()
    ) {
      setCustomDeliveryDate(pickupDateValue);
    }

    setShowDeliveryDatePicker(true);
  };

  const handleContinue = () => {
    setShowErrors(true);

    if (!formIsValid || !loadDetails || !pickupWindow) {
      return;
    }

    const scheduleDetails = {
      ...loadDetails,
      schedule: {
        pickupDate,
        pickupWindow,
        deliveryPreference,
        deliveryDate,
      },
    };

    console.log(scheduleDetails);

    /*
     * Step 4 navigation will replace this console.log after we create:
     * app/post-load/pricing.tsx
     */
  };

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView
        contentContainerStyle={styles.scrollContent}
        keyboardShouldPersistTaps="handled"
        showsVerticalScrollIndicator={false}
      >
        <Pressable
          accessibilityLabel="Go back"
          accessibilityRole="button"
          hitSlop={12}
          onPress={() => router.back()}
          style={({ pressed }) => [
            styles.backButton,
            pressed && styles.pressed,
          ]}
        >
          <Text style={styles.backButtonText}>
            {'\u2190'} Back
          </Text>
        </Pressable>

        <View style={styles.progressHeader}>
          <Text style={styles.step}>STEP 3 OF 5</Text>
          <Text style={styles.progressPercent}>60%</Text>
        </View>

        <View style={styles.progressTrack}>
          <View style={styles.progressFill} />
        </View>

        <Text style={styles.heading}>
          When should it be moved?
        </Text>

        <Text style={styles.description}>
          Choose the preferred pickup date, time window, and
          delivery timing.
        </Text>

        {loadDetails ? (
          <>
            <View style={styles.routeCard}>
              <View style={styles.routeRow}>
                <View style={styles.pickupDot} />

                <View style={styles.routeTextContainer}>
                  <Text style={styles.routeLabel}>Pickup</Text>
                  <Text
                    numberOfLines={1}
                    style={styles.routeValue}
                  >
                    {loadDetails.pickupLocation || 'Not provided'}
                  </Text>
                </View>
              </View>

              <View style={styles.routeDivider} />

              <View style={styles.routeRow}>
                <View style={styles.deliveryDot} />

                <View style={styles.routeTextContainer}>
                  <Text style={styles.routeLabel}>Delivery</Text>
                  <Text
                    numberOfLines={1}
                    style={styles.routeValue}
                  >
                    {loadDetails.deliveryLocation || 'Not provided'}
                  </Text>
                </View>
              </View>
            </View>

            <View style={styles.loadSummaryCard}>
              <Text style={styles.summaryLabel}>Load</Text>

              <Text style={styles.summaryTitle}>
                {loadDetails.description}
              </Text>

              <Text style={styles.summaryDetail}>
                {[
                  loadDetails.category,
                  `${loadDetails.quantity} item${
                    loadDetails.quantity === 1 ? '' : 's'
                  }`,
                  loadDetails.vehicleRequirement,
                ]
                  .filter(Boolean)
                  .join('\u00A0\u2022\u00A0')}
              </Text>
            </View>
          </>
        ) : (
          <View style={styles.dataErrorCard}>
            <Text style={styles.dataErrorTitle}>
              Load details are unavailable
            </Text>

            <Text style={styles.dataErrorText}>
              Go back and complete the previous step again.
            </Text>
          </View>
        )}

        <View style={styles.form}>
          <View style={styles.fieldGroup}>
            <Text style={styles.label}>Pickup date</Text>

            <Text style={styles.fieldDescription}>
              Select when the load will be ready for collection.
            </Text>

            <View style={styles.optionList}>
              <Pressable
                onPress={() => {
                  applyPickupDate(todayDate, 'today');
                  setShowPickupDatePicker(false);
                }}
                style={({ pressed }) => [
                  styles.optionChip,
                  pickupDateMode === 'today' &&
                    styles.optionChipSelected,
                  pressed && styles.pressed,
                ]}
              >
                <Text
                  style={[
                    styles.optionChipText,
                    pickupDateMode === 'today' &&
                      styles.optionChipTextSelected,
                  ]}
                >
                  Today
                </Text>
              </Pressable>

              <Pressable
                onPress={() => {
                  applyPickupDate(tomorrowDate, 'tomorrow');
                  setShowPickupDatePicker(false);
                }}
                style={({ pressed }) => [
                  styles.optionChip,
                  pickupDateMode === 'tomorrow' &&
                    styles.optionChipSelected,
                  pressed && styles.pressed,
                ]}
              >
                <Text
                  style={[
                    styles.optionChipText,
                    pickupDateMode === 'tomorrow' &&
                      styles.optionChipTextSelected,
                  ]}
                >
                  Tomorrow
                </Text>
              </Pressable>

              <Pressable
                onPress={() => {
                  setPickupDateMode('custom');
                  setShowPickupDatePicker(true);
                }}
                style={({ pressed }) => [
                  styles.optionChip,
                  pickupDateMode === 'custom' &&
                    styles.optionChipSelected,
                  pressed && styles.pressed,
                ]}
              >
                <Text
                  style={[
                    styles.optionChipText,
                    pickupDateMode === 'custom' &&
                      styles.optionChipTextSelected,
                  ]}
                >
                  Choose date
                </Text>
              </Pressable>
            </View>

            {pickupDateMode === 'custom' ? (
              <>
                <Pressable
                  accessibilityLabel="Choose pickup date"
                  accessibilityRole="button"
                  onPress={() => setShowPickupDatePicker(true)}
                  style={({ pressed }) => [
                    styles.dateButton,
                    showErrors &&
                      !pickupDateIsValid &&
                      styles.inputError,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text style={styles.dateButtonLabel}>
                    Pickup date
                  </Text>
                  <Text style={styles.dateButtonValue}>
                    {formatDisplayDate(selectedPickupDate)}
                  </Text>
                </Pressable>

                {showPickupDatePicker ? (
                  <View style={styles.pickerContainer}>
                    <DateTimePicker
                      accentColor="#1D4ED8"
                      display={Platform.OS === 'ios' ? 'inline' : 'default'}
                      minimumDate={todayDate}
                      mode="date"
                      onChange={handlePickupDateChange}
                      style={styles.datePicker}
                      themeVariant="light"
                      value={selectedPickupDate}
                   />

                    {Platform.OS === 'ios' ? (
                      <Pressable
                        onPress={() =>
                          setShowPickupDatePicker(false)
                        }
                        style={styles.pickerDoneButton}
                      >
                        <Text style={styles.pickerDoneText}>
                          Done
                        </Text>
                      </Pressable>
                    ) : null}
                  </View>
                ) : null}
              </>
            ) : (
              <Text style={styles.selectedDateText}>
                {formatDisplayDate(pickupDateValue)}
              </Text>
            )}

            {showErrors && !pickupDateIsValid ? (
              <Text style={styles.errorText}>
                Choose a pickup date that is not in the past.
              </Text>
            ) : null}
          </View>

          <View style={styles.fieldGroup}>
            <Text style={styles.label}>
              Pickup time window
            </Text>

            <View style={styles.selectionCardList}>
              {PICKUP_WINDOWS.map((option) => {
                const isSelected =
                  pickupWindow === option.value;

                return (
                  <Pressable
                    key={option.value}
                    onPress={() =>
                      setPickupWindow(option.value)
                    }
                    style={({ pressed }) => [
                      styles.selectionCard,
                      isSelected &&
                        styles.selectionCardSelected,
                      pressed && styles.pressed,
                    ]}
                  >
                    <View style={styles.selectionTextContainer}>
                      <Text
                        style={[
                          styles.selectionTitle,
                          isSelected &&
                            styles.selectionTitleSelected,
                        ]}
                      >
                        {option.label}
                      </Text>

                      <Text style={styles.selectionDetail}>
                        {option.detail}
                      </Text>
                    </View>

                    <View
                      style={[
                        styles.radioOuter,
                        isSelected && styles.radioOuterSelected,
                      ]}
                    >
                      {isSelected ? (
                        <View style={styles.radioInner} />
                      ) : null}
                    </View>
                  </Pressable>
                );
              })}
            </View>

            {showErrors && !pickupWindowIsValid ? (
              <Text style={styles.errorText}>
                Select a pickup time window.
              </Text>
            ) : null}
          </View>

          <View style={styles.fieldGroup}>
            <Text style={styles.label}>Delivery timing</Text>

            <Text style={styles.fieldDescription}>
              Choose when the load should arrive.
            </Text>

            <View style={styles.selectionCardList}>
              {DELIVERY_OPTIONS.map((option) => {
                const isSelected =
                  deliveryPreference === option.value;

                return (
                  <Pressable
                    key={option.value}
                    onPress={() =>
                      handleDeliveryPreferenceChange(
                        option.value,
                      )
                    }
                    style={({ pressed }) => [
                      styles.selectionCard,
                      isSelected &&
                        styles.selectionCardSelected,
                      pressed && styles.pressed,
                    ]}
                  >
                    <View style={styles.selectionTextContainer}>
                      <Text
                        style={[
                          styles.selectionTitle,
                          isSelected &&
                            styles.selectionTitleSelected,
                        ]}
                      >
                        {option.label}
                      </Text>

                      <Text style={styles.selectionDetail}>
                        {option.detail}
                      </Text>
                    </View>

                    <View
                      style={[
                        styles.radioOuter,
                        isSelected && styles.radioOuterSelected,
                      ]}
                    >
                      {isSelected ? (
                        <View style={styles.radioInner} />
                      ) : null}
                    </View>
                  </Pressable>
                );
              })}
            </View>

            {deliveryPreference === 'scheduled' ? (
              <>
                <Pressable
                  accessibilityLabel="Choose delivery date"
                  accessibilityRole="button"
                  onPress={() => setShowDeliveryDatePicker(true)}
                  style={({ pressed }) => [
                    styles.dateButton,
                    showErrors &&
                      (!scheduledDeliveryDateIsValid ||
                        !scheduledDeliveryIsNotBeforePickup) &&
                      styles.inputError,
                    pressed && styles.pressed,
                  ]}
                >
                  <Text style={styles.dateButtonLabel}>
                    Delivery date
                  </Text>
                  <Text style={styles.dateButtonValue}>
                    {customDeliveryDate
                      ? formatDisplayDate(customDeliveryDate)
                      : 'Choose a date'}
                  </Text>
                </Pressable>

                {showDeliveryDatePicker ? (
                  <View style={styles.pickerContainer}>
                    <DateTimePicker
                      accentColor="#1D4ED8"
                      display={Platform.OS === 'ios' ? 'inline' : 'default'}
                      minimumDate={pickupDateValue}
                      mode="date"
                      onChange={handleDeliveryDateChange}
                      style={styles.datePicker}
                      themeVariant="light"
                      value={customDeliveryDate ?? pickupDateValue}
                    />

                    {Platform.OS === 'ios' ? (
                      <Pressable
                        onPress={() =>
                          setShowDeliveryDatePicker(false)
                        }
                        style={styles.pickerDoneButton}
                      >
                        <Text style={styles.pickerDoneText}>
                          Done
                        </Text>
                      </Pressable>
                    ) : null}
                  </View>
                ) : null}
              </>
            ) : null}

            {showErrors && !deliveryPreferenceIsValid ? (
              <Text style={styles.errorText}>
                Select a delivery timing preference.
              </Text>
            ) : null}

            {showErrors &&
            deliveryPreference === 'scheduled' &&
            !scheduledDeliveryDateIsValid ? (
              <Text style={styles.errorText}>
                Choose a delivery date.
              </Text>
            ) : null}

            {showErrors &&
            deliveryPreference === 'scheduled' &&
            scheduledDeliveryDateIsValid &&
            !scheduledDeliveryIsNotBeforePickup ? (
              <Text style={styles.errorText}>
                Delivery cannot be scheduled before pickup.
              </Text>
            ) : null}
          </View>
        </View>

        <Pressable
          accessibilityLabel="Continue to pricing"
          accessibilityRole="button"
          onPress={handleContinue}
          style={({ pressed }) => [
            styles.continueButton,
            pressed && styles.continueButtonPressed,
          ]}
        >
          <Text style={styles.continueButtonText}>
            Continue {'\u2192'}
          </Text>
        </Pressable>
      </ScrollView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F7F9FC',
  },
  scrollContent: {
    flexGrow: 1,
    paddingHorizontal: 24,
    paddingTop: 24,
    paddingBottom: 40,
  },
  backButton: {
    alignSelf: 'flex-start',
    paddingVertical: 12,
  },
  backButtonText: {
    color: '#1D4ED8',
    fontSize: 16,
    fontWeight: '700',
  },
  pressed: {
    opacity: 0.7,
  },
  progressHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    marginTop: 28,
  },
  step: {
    color: '#1D4ED8',
    fontSize: 13,
    fontWeight: '800',
    letterSpacing: 1,
  },
  progressPercent: {
    color: '#6B7280',
    fontSize: 13,
    fontWeight: '700',
  },
  progressTrack: {
    backgroundColor: '#DDE5F3',
    borderRadius: 999,
    height: 6,
    marginTop: 12,
    overflow: 'hidden',
  },
  progressFill: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: '100%',
    width: '60%',
  },
  heading: {
    color: '#111827',
    fontSize: 34,
    fontWeight: '800',
    lineHeight: 41,
    marginTop: 30,
  },
  description: {
    color: '#6B7280',
    fontSize: 17,
    lineHeight: 26,
    marginTop: 12,
  },
  routeCard: {
    backgroundColor: '#FFFFFF',
    borderColor: '#E2E7EF',
    borderRadius: 18,
    borderWidth: 1,
    marginTop: 26,
    padding: 18,
  },
  routeRow: {
    alignItems: 'center',
    flexDirection: 'row',
  },
  pickupDot: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: 10,
    marginRight: 14,
    width: 10,
  },
  deliveryDot: {
    backgroundColor: '#16A34A',
    borderRadius: 2,
    height: 10,
    marginRight: 14,
    width: 10,
  },
  routeTextContainer: {
    flex: 1,
  },
  routeLabel: {
    color: '#6B7280',
    fontSize: 12,
    fontWeight: '700',
    textTransform: 'uppercase',
  },
  routeValue: {
    color: '#111827',
    fontSize: 15,
    fontWeight: '700',
    marginTop: 3,
  },
  routeDivider: {
    backgroundColor: '#E5E7EB',
    height: 1,
    marginLeft: 24,
    marginVertical: 14,
  },
  loadSummaryCard: {
    backgroundColor: '#EEF3FF',
    borderRadius: 18,
    marginTop: 14,
    padding: 18,
  },
  summaryLabel: {
    color: '#1D4ED8',
    fontSize: 12,
    fontWeight: '800',
    letterSpacing: 0.7,
    textTransform: 'uppercase',
  },
  summaryTitle: {
    color: '#111827',
    fontSize: 17,
    fontWeight: '800',
    marginTop: 7,
  },
  summaryDetail: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 5,
  },
  dataErrorCard: {
    backgroundColor: '#FEF2F2',
    borderColor: '#FECACA',
    borderRadius: 16,
    borderWidth: 1,
    marginTop: 26,
    padding: 18,
  },
  dataErrorTitle: {
    color: '#991B1B',
    fontSize: 15,
    fontWeight: '800',
  },
  dataErrorText: {
    color: '#B91C1C',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 5,
  },
  form: {
    marginTop: 32,
  },
  fieldGroup: {
    marginBottom: 30,
  },
  label: {
    color: '#111827',
    fontSize: 16,
    fontWeight: '800',
    marginBottom: 8,
  },
  fieldDescription: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 19,
    marginBottom: 14,
  },
  optionList: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    gap: 10,
  },
  optionChip: {
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE1E9',
    borderRadius: 999,
    borderWidth: 1,
    paddingHorizontal: 16,
    paddingVertical: 12,
  },
  optionChipSelected: {
    backgroundColor: '#E8EEFF',
    borderColor: '#1D4ED8',
  },
  optionChipText: {
    color: '#4B5563',
    fontSize: 14,
    fontWeight: '700',
  },
  optionChipTextSelected: {
    color: '#1D4ED8',
  },
  selectedDateText: {
    color: '#6B7280',
    fontSize: 13,
    marginTop: 11,
  },
  dateButton: {
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE1E9',
    borderRadius: 16,
    borderWidth: 1,
    justifyContent: 'center',
    marginTop: 14,
    minHeight: 68,
    paddingHorizontal: 18,
    paddingVertical: 11,
  },
  dateButtonLabel: {
    color: '#6B7280',
    fontSize: 12,
    fontWeight: '700',
  },
  dateButtonValue: {
    color: '#111827',
    fontSize: 16,
    fontWeight: '800',
    marginTop: 4,
  },
  pickerContainer: {
  backgroundColor: '#EEF3FF',
  borderColor: '#CBD5E1',
  borderRadius: 16,
  borderWidth: 1,
  marginTop: 10,
  overflow: 'hidden',
  paddingHorizontal: Platform.OS === 'ios' ? 6 : 0,
  paddingTop: Platform.OS === 'ios' ? 4 : 0,
  paddingBottom: Platform.OS === 'ios' ? 6 : 0,
},
datePicker: {
  alignSelf: 'stretch',
  backgroundColor: '#EEF3FF',
},
  pickerDoneButton: {
  alignSelf: 'stretch',
  alignItems: 'flex-end',
  borderTopColor: '#D5DEEF',
  borderTopWidth: 1,
  paddingHorizontal: 16,
  paddingVertical: 11,
},
  pickerDoneText: {
    color: '#1D4ED8',
    fontSize: 15,
    fontWeight: '800',
  },
  inputError: {
    borderColor: '#DC2626',
  },
  errorText: {
    color: '#DC2626',
    fontSize: 13,
    fontWeight: '600',
    lineHeight: 19,
    marginTop: 9,
  },
  selectionCardList: {
    gap: 11,
  },
  selectionCard: {
    alignItems: 'center',
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE1E9',
    borderRadius: 16,
    borderWidth: 1,
    flexDirection: 'row',
    justifyContent: 'space-between',
    minHeight: 72,
    paddingHorizontal: 17,
    paddingVertical: 13,
  },
  selectionCardSelected: {
    backgroundColor: '#EEF3FF',
    borderColor: '#1D4ED8',
  },
  selectionTextContainer: {
    flex: 1,
    paddingRight: 14,
  },
  selectionTitle: {
    color: '#111827',
    fontSize: 15,
    fontWeight: '800',
  },
  selectionTitleSelected: {
    color: '#1D4ED8',
  },
  selectionDetail: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 18,
    marginTop: 3,
  },
  radioOuter: {
    alignItems: 'center',
    borderColor: '#C7CED9',
    borderRadius: 999,
    borderWidth: 2,
    height: 22,
    justifyContent: 'center',
    width: 22,
  },
  radioOuterSelected: {
    borderColor: '#1D4ED8',
  },
  radioInner: {
    backgroundColor: '#1D4ED8',
    borderRadius: 999,
    height: 10,
    width: 10,
  },
  continueButton: {
    alignItems: 'center',
    backgroundColor: '#1D4ED8',
    borderRadius: 16,
    justifyContent: 'center',
    marginTop: 4,
    minHeight: 58,
    paddingHorizontal: 20,
  },
  continueButtonPressed: {
    opacity: 0.82,
    transform: [{ scale: 0.99 }],
  },
  continueButtonText: {
    color: '#FFFFFF',
    fontSize: 17,
    fontWeight: '800',
  },
});
