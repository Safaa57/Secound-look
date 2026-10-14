package com.google.i18n.phonenumbers;
import com.google.i18n.phonenumbers.Phonenumber.PhoneNumber;
public class PhoneNumberUtil {
  public enum PhoneNumberFormat { E164, INTERNATIONAL, NATIONAL, RFC3966 }
  public enum PhoneNumberType { FIXED_LINE, MOBILE, FIXED_LINE_OR_MOBILE, TOLL_FREE, PREMIUM_RATE, SHARED_COST, VOIP, PERSONAL_NUMBER, PAGER, UAN, VOICEMAIL, UNKNOWN }
  public static PhoneNumberUtil getInstance() { return null; }
  public PhoneNumber parse(CharSequence n, String r) throws NumberParseException { return null; }
  public boolean isValidNumber(PhoneNumber n) { return false; }
  public boolean isPossibleNumber(PhoneNumber n) { return false; }
  public String format(PhoneNumber n, PhoneNumberFormat f) { return null; }
  public String getRegionCodeForNumber(PhoneNumber n) { return null; }
  public String getRegionCodeForCountryCode(int c) { return null; }
  public PhoneNumberType getNumberType(PhoneNumber n) { return null; }
}
