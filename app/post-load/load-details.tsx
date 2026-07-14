import { router, useLocalSearchParams } from 'expo-router';
import { useState } from 'react';
import {
  KeyboardAvoidingView,
  Platform,
  Pressable,
  SafeAreaView,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from 'react-native';

const LOAD_CATEGORIES = [
  'Furniture',
  'Appliances',
  'Electronics',
  'Boxes / Parcels',
  'Building Materials',
  'Automotive Parts',
  'Other',
] as const;

const VEHICLE_REQUIREMENTS = [
  'Car',
  'SUV',
  'Pickup Truck',
  'Cargo Van',
  'Sprinter Van',
  'Box Truck',
  'Not sure',
] as const;

type LoadCategory = (typeof LOAD_CATEGORIES)[number];
type VehicleRequirement = (typeof VEHICLE_REQUIREMENTS)[number];
type WeightUnit = 'lb' | 'kg';
type DimensionUnit = 'in' | 'cm';

function isOptionalPositiveNumber(value: string) {
  if (value.trim() === '') {
    return true;
  }

  const numericValue = Number(value);

  return Number.isFinite(numericValue) && numericValue > 0;
}

export default function LoadDetailsScreen() {
  const params = useLocalSearchParams<{
    pickupLocation?: string;
    deliveryLocation?: string;
  }>();

  const [description, setDescription] = useState('');
  const [category, setCategory] = useState<LoadCategory | null>(null);
  const [quantity, setQuantity] = useState('1');

  const [weight, setWeight] = useState('');
  const [weightUnit, setWeightUnit] = useState<WeightUnit>('lb');

  const [length, setLength] = useState('');
  const [width, setWidth] = useState('');
  const [height, setHeight] = useState('');
  const [dimensionUnit, setDimensionUnit] =
    useState<DimensionUnit>('in');

  const [vehicleRequirement, setVehicleRequirement] =
    useState<VehicleRequirement | null>(null);

  const [specialInstructions, setSpecialInstructions] = useState('');
  const [showErrors, setShowErrors] = useState(false);

  const descriptionIsValid = description.trim().length >= 3;
  const categoryIsValid = category !== null;

  const quantityNumber = Number(quantity);
  const quantityIsValid =
    quantity.trim().length > 0 &&
    Number.isInteger(quantityNumber) &&
    quantityNumber > 0;

  const weightIsValid = isOptionalPositiveNumber(weight);

  const lengthIsValid = isOptionalPositiveNumber(length);
  const widthIsValid = isOptionalPositiveNumber(width);
  const heightIsValid = isOptionalPositiveNumber(height);

  const hasAnyDimension =
    length.trim() !== '' ||
    width.trim() !== '' ||
    height.trim() !== '';

  const hasAllDimensions =
    length.trim() !== '' &&
    width.trim() !== '' &&
    height.trim() !== '';

  const dimensionsAreValid =
    (!hasAnyDimension || hasAllDimensions) &&
    lengthIsValid &&
    widthIsValid &&
    heightIsValid;

  const vehicleRequirementIsValid = vehicleRequirement !== null;

  const formIsValid =
    descriptionIsValid &&
    categoryIsValid &&
    quantityIsValid &&
    weightIsValid &&
    dimensionsAreValid &&
    vehicleRequirementIsValid;

  const handleContinue = () => {
    setShowErrors(true);

    if (!formIsValid) {
      return;
    }

    const loadDetails = {
      pickupLocation: params.pickupLocation,
      deliveryLocation: params.deliveryLocation,
      description: description.trim(),
      category,
      quantity: quantityNumber,
      weight: weight.trim() ? Number(weight) : null,
      weightUnit,
      dimensions: hasAllDimensions
        ? {
            length: Number(length),
            width: Number(width),
            height: Number(height),
            unit: dimensionUnit,
          }
        : null,
      vehicleRequirement,
      specialInstructions: specialInstructions.trim() || null,
    };

    console.log(loadDetails);

    router.push({
  pathname: '/post-load/schedule',
  params: {
    loadDetails: JSON.stringify(loadDetails),
  },
});
  };

  return (
    <SafeAreaView style={styles.container}>
      <KeyboardAvoidingView
        behavior={Platform.OS === 'ios' ? 'padding' : undefined}
        style={styles.keyboardView}
      >
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
            <Text style={styles.step}>STEP 2 OF 5</Text>
            <Text style={styles.progressPercent}>40%</Text>
          </View>

          <View style={styles.progressTrack}>
            <View style={styles.progressFill} />
          </View>

          <Text style={styles.heading}>What are you sending?</Text>

          <Text style={styles.description}>
            Give drivers enough information to understand the size and type of
            load.
          </Text>

          <View style={styles.routeCard}>
            <View style={styles.routeRow}>
              <View style={styles.pickupDot} />

              <View style={styles.routeTextContainer}>
                <Text style={styles.routeLabel}>Pickup</Text>
                <Text numberOfLines={1} style={styles.routeValue}>
                  {params.pickupLocation || 'Not provided'}
                </Text>
              </View>
            </View>

            <View style={styles.routeDivider} />

            <View style={styles.routeRow}>
              <View style={styles.deliveryDot} />

              <View style={styles.routeTextContainer}>
                <Text style={styles.routeLabel}>Delivery</Text>
                <Text numberOfLines={1} style={styles.routeValue}>
                  {params.deliveryLocation || 'Not provided'}
                </Text>
              </View>
            </View>
          </View>

          <View style={styles.form}>
            <View style={styles.fieldGroup}>
              <Text style={styles.label}>Describe the load</Text>

              <TextInput
                multiline
                onChangeText={setDescription}
                placeholder="Example: One boxed office chair"
                placeholderTextColor="#9CA3AF"
                style={[
                  styles.textArea,
                  showErrors &&
                    !descriptionIsValid &&
                    styles.inputError,
                ]}
                textAlignVertical="top"
                value={description}
              />

              {showErrors && !descriptionIsValid ? (
                <Text style={styles.errorText}>
                  Enter a brief load description.
                </Text>
              ) : (
                <Text style={styles.helperText}>
                  Include what the item is and whether it is boxed, assembled,
                  fragile, or unusually shaped.
                </Text>
              )}
            </View>

            <View style={styles.fieldGroup}>
              <Text style={styles.label}>Load category</Text>

              <View style={styles.optionList}>
                {LOAD_CATEGORIES.map((option) => {
                  const isSelected = category === option;

                  return (
                    <Pressable
                      key={option}
                      onPress={() => setCategory(option)}
                      style={({ pressed }) => [
                        styles.optionChip,
                        isSelected && styles.optionChipSelected,
                        pressed && styles.pressed,
                      ]}
                    >
                      <Text
                        style={[
                          styles.optionChipText,
                          isSelected && styles.optionChipTextSelected,
                        ]}
                      >
                        {option}
                      </Text>
                    </Pressable>
                  );
                })}
              </View>

              {showErrors && !categoryIsValid ? (
                <Text style={styles.errorText}>
                  Select a load category.
                </Text>
              ) : null}
            </View>

            <View style={styles.fieldGroup}>
              <Text style={styles.label}>Quantity</Text>

              <TextInput
                keyboardType="number-pad"
                onChangeText={setQuantity}
                placeholder="1"
                placeholderTextColor="#9CA3AF"
                style={[
                  styles.input,
                  showErrors && !quantityIsValid && styles.inputError,
                ]}
                value={quantity}
              />

              {showErrors && !quantityIsValid ? (
                <Text style={styles.errorText}>
                  Enter a valid whole-number quantity.
                </Text>
              ) : null}
            </View>

            <View style={styles.fieldGroup}>
              <Text style={styles.label}>
                Estimated total weight
                <Text style={styles.optionalLabel}> Optional</Text>
              </Text>

              <View style={styles.measurementRow}>
                <TextInput
                  keyboardType="decimal-pad"
                  onChangeText={setWeight}
                  placeholder="Enter weight"
                  placeholderTextColor="#9CA3AF"
                  style={[
                    styles.measurementInput,
                    showErrors && !weightIsValid && styles.inputError,
                  ]}
                  value={weight}
                />

                <View style={styles.unitSelector}>
                  {(['lb', 'kg'] as const).map((unit) => {
                    const isSelected = weightUnit === unit;

                    return (
                      <Pressable
                        key={unit}
                        onPress={() => setWeightUnit(unit)}
                        style={[
                          styles.unitOption,
                          isSelected && styles.unitOptionSelected,
                        ]}
                      >
                        <Text
                          style={[
                            styles.unitText,
                            isSelected && styles.unitTextSelected,
                          ]}
                        >
                          {unit}
                        </Text>
                      </Pressable>
                    );
                  })}
                </View>
              </View>

              {showErrors && !weightIsValid ? (
                <Text style={styles.errorText}>
                  Enter a weight greater than zero.
                </Text>
              ) : null}
            </View>

            <View style={styles.fieldGroup}>
              <View style={styles.sectionLabelRow}>
                <Text style={styles.label}>
                  Dimensions
                  <Text style={styles.optionalLabel}> Optional</Text>
                </Text>

                <View style={styles.compactUnitSelector}>
                  {(['in', 'cm'] as const).map((unit) => {
                    const isSelected = dimensionUnit === unit;

                    return (
                      <Pressable
                        key={unit}
                        onPress={() => setDimensionUnit(unit)}
                        style={[
                          styles.compactUnitOption,
                          isSelected && styles.unitOptionSelected,
                        ]}
                      >
                        <Text
                          style={[
                            styles.unitText,
                            isSelected && styles.unitTextSelected,
                          ]}
                        >
                          {unit}
                        </Text>
                      </Pressable>
                    );
                  })}
                </View>
              </View>

              <View style={styles.dimensionsRow}>
                <View style={styles.dimensionField}>
                  <Text style={styles.dimensionLabel}>Length</Text>
                  <TextInput
                    keyboardType="decimal-pad"
                    onChangeText={setLength}
                    placeholder="0"
                    placeholderTextColor="#9CA3AF"
                    style={[
                      styles.dimensionInput,
                      showErrors &&
                        !dimensionsAreValid &&
                        styles.inputError,
                    ]}
                    value={length}
                  />
                </View>

                <View style={styles.dimensionField}>
                  <Text style={styles.dimensionLabel}>Width</Text>
                  <TextInput
                    keyboardType="decimal-pad"
                    onChangeText={setWidth}
                    placeholder="0"
                    placeholderTextColor="#9CA3AF"
                    style={[
                      styles.dimensionInput,
                      showErrors &&
                        !dimensionsAreValid &&
                        styles.inputError,
                    ]}
                    value={width}
                  />
                </View>

                <View style={styles.dimensionField}>
                  <Text style={styles.dimensionLabel}>Height</Text>
                  <TextInput
                    keyboardType="decimal-pad"
                    onChangeText={setHeight}
                    placeholder="0"
                    placeholderTextColor="#9CA3AF"
                    style={[
                      styles.dimensionInput,
                      showErrors &&
                        !dimensionsAreValid &&
                        styles.inputError,
                    ]}
                    value={height}
                  />
                </View>
              </View>

              {showErrors && !dimensionsAreValid ? (
                <Text style={styles.errorText}>
                  Enter all three dimensions using values greater than zero, or
                  leave all three blank.
                </Text>
              ) : (
                <Text style={styles.helperText}>
                  Measure the widest points of the complete load.
                </Text>
              )}
            </View>

            <View style={styles.fieldGroup}>
              <Text style={styles.label}>Vehicle requirement</Text>

              <Text style={styles.fieldDescription}>
                Select the smallest vehicle that could reasonably carry the
                load.
              </Text>

              <View style={styles.optionList}>
                {VEHICLE_REQUIREMENTS.map((option) => {
                  const isSelected = vehicleRequirement === option;

                  return (
                    <Pressable
                      key={option}
                      onPress={() => setVehicleRequirement(option)}
                      style={({ pressed }) => [
                        styles.optionChip,
                        isSelected && styles.optionChipSelected,
                        pressed && styles.pressed,
                      ]}
                    >
                      <Text
                        style={[
                          styles.optionChipText,
                          isSelected && styles.optionChipTextSelected,
                        ]}
                      >
                        {option}
                      </Text>
                    </Pressable>
                  );
                })}
              </View>

              {showErrors && !vehicleRequirementIsValid ? (
                <Text style={styles.errorText}>
                  Select a vehicle requirement or choose Not sure.
                </Text>
              ) : null}
            </View>

            <View style={styles.fieldGroup}>
              <Text style={styles.label}>
                Special handling instructions
                <Text style={styles.optionalLabel}> Optional</Text>
              </Text>

              <TextInput
                multiline
                maxLength={500}
                onChangeText={setSpecialInstructions}
                placeholder="Example: Keep upright, two people required, loading dock access..."
                placeholderTextColor="#9CA3AF"
                style={styles.textArea}
                textAlignVertical="top"
                value={specialInstructions}
              />

              <Text style={styles.characterCount}>
                {specialInstructions.length}/500
              </Text>
            </View>
          </View>

          <Pressable
            accessibilityLabel="Continue to scheduling"
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
      </KeyboardAvoidingView>
    </SafeAreaView>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#F7F9FC',
  },
  keyboardView: {
    flex: 1,
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
    width: '40%',
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
  form: {
    marginTop: 30,
  },
  fieldGroup: {
    marginBottom: 28,
  },
  sectionLabelRow: {
    alignItems: 'center',
    flexDirection: 'row',
    justifyContent: 'space-between',
  },
  label: {
    color: '#111827',
    fontSize: 15,
    fontWeight: '700',
    marginBottom: 9,
  },
  optionalLabel: {
    color: '#6B7280',
    fontSize: 13,
    fontWeight: '500',
  },
  fieldDescription: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 19,
    marginBottom: 13,
    marginTop: -2,
  },
  input: {
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE1E9',
    borderRadius: 16,
    borderWidth: 1,
    color: '#111827',
    fontSize: 16,
    minHeight: 60,
    paddingHorizontal: 18,
  },
  textArea: {
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE1E9',
    borderRadius: 16,
    borderWidth: 1,
    color: '#111827',
    fontSize: 16,
    minHeight: 118,
    padding: 18,
  },
  inputError: {
    borderColor: '#DC2626',
  },
  helperText: {
    color: '#6B7280',
    fontSize: 13,
    lineHeight: 19,
    marginTop: 8,
  },
  errorText: {
    color: '#DC2626',
    fontSize: 13,
    fontWeight: '600',
    lineHeight: 19,
    marginTop: 8,
  },
  characterCount: {
    color: '#6B7280',
    fontSize: 12,
    marginTop: 7,
    textAlign: 'right',
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
    paddingHorizontal: 15,
    paddingVertical: 11,
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
  measurementRow: {
    flexDirection: 'row',
    gap: 12,
  },
  measurementInput: {
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE1E9',
    borderRadius: 16,
    borderWidth: 1,
    color: '#111827',
    flex: 1,
    fontSize: 16,
    minHeight: 60,
    paddingHorizontal: 18,
  },
  unitSelector: {
    backgroundColor: '#E8EDF5',
    borderRadius: 14,
    flexDirection: 'row',
    padding: 4,
  },
  compactUnitSelector: {
    backgroundColor: '#E8EDF5',
    borderRadius: 12,
    flexDirection: 'row',
    marginBottom: 8,
    padding: 3,
  },
  unitOption: {
    alignItems: 'center',
    borderRadius: 11,
    justifyContent: 'center',
    minWidth: 50,
    paddingHorizontal: 12,
  },
  compactUnitOption: {
    alignItems: 'center',
    borderRadius: 9,
    justifyContent: 'center',
    minHeight: 34,
    minWidth: 43,
    paddingHorizontal: 10,
  },
  unitOptionSelected: {
    backgroundColor: '#FFFFFF',
  },
  unitText: {
    color: '#6B7280',
    fontSize: 14,
    fontWeight: '700',
  },
  unitTextSelected: {
    color: '#1D4ED8',
  },
  dimensionsRow: {
    flexDirection: 'row',
    gap: 10,
  },
  dimensionField: {
    flex: 1,
  },
  dimensionLabel: {
    color: '#6B7280',
    fontSize: 12,
    fontWeight: '700',
    marginBottom: 7,
  },
  dimensionInput: {
    backgroundColor: '#FFFFFF',
    borderColor: '#DCE1E9',
    borderRadius: 14,
    borderWidth: 1,
    color: '#111827',
    fontSize: 16,
    minHeight: 56,
    paddingHorizontal: 14,
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